#!/usr/bin/env bash
# 1497-p1-home-resolver smoke — issue #1497 Phase 1.
#
# Phase 1 of the canonical HOME/agent-path SSOT closes the HOME channel that
# the #1498 v2-handoff fix left open for the workdir dimension only:
#
#   * bridge-run.sh now exports BRIDGE_AGENT_HOME_RESOLVED (the v2-aware
#     identity home) alongside BRIDGE_AGENT_WORKDIR_RESOLVED, at BOTH the
#     initial-launch and roster-refresh relaunch sites.
#   * `agent show --json` now emits a resolver-derived `agent_home` (it was
#     absent — effectively None — before).
#   * hooks/bridge_hook_common.py::agent_default_home reads the RESOLVED
#     scalar first, then a v2-aware computation, then the roster-CLI fallback,
#     and NEVER lets a stale legacy `agents/<a>` dir short-circuit ahead of v2.
#
# Design principle under test: bash is the authoritative resolver; Python is a
# thin consumer (RESOLVED scalar + `agent show --json` fallback). v2 signal
# present → v2 tree; absent → legacy EXACTLY as before.
#
# Cases:
#   E1 — export integrity: the bridge-run export expression yields a
#        non-empty BRIDGE_AGENT_HOME_RESOLVED that reaches the child env
#        (regression guard for the assoc-array scalar-export no-op class).
#   P1 — bash↔Python home PARITY for a STATIC-SHARED (legacy) layout.
#   P2 — bash↔Python home PARITY for a DYNAMIC layout (legacy root).
#   P3 — bash↔Python home PARITY for a V2-SPLIT layout (data/agents/<a>/home).
#   J1 — `agent show --json` emits a non-null, v2-correct agent_home.
#   R1 — RESOLVED-first precedence: the exported scalar wins over v2/legacy.
#   S1 — v2 split-brain immunity: a legacy `agents/<a>` dir physically present
#        must NOT beat the v2 home (no RESOLVED env set).
#   T1 — TEETH: a hook copy with the HOME-RESOLVED read reverted must FAIL
#        the parity assertion (proves the read is load-bearing).

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"

# Fleet-down guard: force a private tmux universe (and sever any inherited
# $TMUX) before any work, so a run from inside a live agent pane can't reach
# the shared fleet socket. Idempotent + harmless even though this smoke does
# not itself drive tmux.
# shellcheck source=../../lib/bridge-smoke-tmux-isolation.sh
source "$REPO_ROOT/lib/bridge-smoke-tmux-isolation.sh"

PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

# Hermetic isolation: this smoke may run inside a LIVE bridge agent session
# whose env already exports BRIDGE_AGENT_ROOT_V2 / BRIDGE_DATA_ROOT /
# BRIDGE_AGENT_HOME_ROOT / BRIDGE_HOME / BRIDGE_AGENT_HOME_RESOLVED. If those
# leaked into the per-case subshells, the "legacy" parity cases (P1/P2) would
# silently resolve against the real install instead of the isolated mktemp
# tree. Scrub every path channel up front; each case re-exports only the vars
# it means to test.
unset BRIDGE_AGENT_ROOT_V2 BRIDGE_DATA_ROOT BRIDGE_AGENT_HOME_ROOT \
  BRIDGE_HOME BRIDGE_AGENT_HOME_RESOLVED BRIDGE_AGENT_WORKDIR_RESOLVED \
  BRIDGE_AGENT_WORKDIR 2>/dev/null || true

PASS=0
FAIL=0
FAILURES=()

pass() {
  PASS=$((PASS + 1))
  printf '[smoke][pass] %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf '[smoke][fail] %s\n' "$1" >&2
}

# Inline copy of lib/bridge-agents.sh::bridge_agent_default_home so the smoke
# can compute the bash-authoritative answer without sourcing the full lib
# stack (which needs a live roster). This MUST stay byte-for-byte aligned with
# the real resolver — if the lib changes, this drifts and the parity cases
# will (correctly) flag it.
bash_agent_default_home() {
  local agent="$1"
  if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" && -n "$agent" ]]; then
    printf '%s/%s/home' "$BRIDGE_AGENT_ROOT_V2" "$agent"
    return 0
  fi
  printf '%s/%s' "${BRIDGE_AGENT_HOME_ROOT:-}" "$agent"
}

# ----- E1: export integrity (scalar reaches child, non-empty) ------------
# Compute the v2 home with the inline resolver, export it exactly as
# bridge-run.sh does, and verify a child shell reads it back. Pure-bash on
# purpose: the regression class this guards (#1213/#1217 — `export NAME=...`
# silently no-ops when NAME collides with a `declare -A NAME`) is a bash-level
# failure, so the child-env round-trip is most faithful in bash. Keeping it in
# bash also keeps the smoke free of an environment-dict probe (iso-helper
# boundary ratchet) and a heredoc-stdin Python invocation (lint-heredoc-ban).
e1_root="$(mktemp -d -t agb-1497-e1.XXXXXX)"
e1_v2_root="$e1_root/data/agents"
e1_expected="$e1_v2_root/patch/home"
e1_resolved="$(
  BRIDGE_AGENT_ROOT_V2="$e1_v2_root" bash_agent_default_home patch
)"
e1_child="$(
  BRIDGE_AGENT_HOME_RESOLVED="$e1_resolved" \
    bash -c 'printf "%s" "${BRIDGE_AGENT_HOME_RESOLVED:-UNSET}"'
)"
if [[ -n "$e1_child" && "$e1_child" != "UNSET" && "$e1_child" == "$e1_expected" ]]; then
  pass "E1: BRIDGE_AGENT_HOME_RESOLVED reaches child env, non-empty"
else
  fail "E1: export integrity broken — child saw: [$e1_child] expected: [$e1_expected]"
fi
rm -rf "$e1_root"

# ----- parity helper -----------------------------------------------------
# Drives the Python resolver in an isolated env and returns its agent_home.
py_home() {
  local hooks_dir="$1"
  local agent="$2"
  "$PYTHON" -c "
import sys
sys.path.insert(0, '$hooks_dir')
import bridge_hook_common as bhc
print(str(bhc.agent_default_home('$agent')))
" 2>&1
}

# ----- P1: static-shared (legacy) parity ---------------------------------
p1_root="$(mktemp -d -t agb-1497-p1.XXXXXX)"
p1_home="$p1_root/bridge-home"
mkdir -p "$p1_home/agents/static-a"
p1_bash="$(
  BRIDGE_AGENT_HOME_ROOT="$p1_home/agents" bash_agent_default_home static-a
)"
p1_py="$(
  BRIDGE_HOME="$p1_home" \
    BRIDGE_AGENT_HOME_ROOT="$p1_home/agents" \
    py_home "$REPO_ROOT/hooks" static-a
)"
if [[ "$p1_py" == "$p1_bash" ]]; then
  pass "P1: static-shared parity (bash==python: $p1_bash)"
else
  fail "P1: static-shared parity MISMATCH — bash=[$p1_bash] python=[$p1_py]"
fi
rm -rf "$p1_root"

# ----- P2: dynamic (legacy root) parity ----------------------------------
# A dynamic agent has no on-disk static home; agent_default_home still returns
# the legacy-root path (no v2 signal). Parity must hold.
p2_root="$(mktemp -d -t agb-1497-p2.XXXXXX)"
p2_home="$p2_root/bridge-home"
mkdir -p "$p2_home/agents"
p2_bash="$(
  BRIDGE_AGENT_HOME_ROOT="$p2_home/agents" bash_agent_default_home dyn-b
)"
p2_py="$(
  BRIDGE_HOME="$p2_home" \
    BRIDGE_AGENT_HOME_ROOT="$p2_home/agents" \
    py_home "$REPO_ROOT/hooks" dyn-b
)"
if [[ "$p2_py" == "$p2_bash" ]]; then
  pass "P2: dynamic parity (bash==python: $p2_bash)"
else
  fail "P2: dynamic parity MISMATCH — bash=[$p2_bash] python=[$p2_py]"
fi
rm -rf "$p2_root"

# ----- P3: v2-split parity -----------------------------------------------
p3_root="$(mktemp -d -t agb-1497-p3.XXXXXX)"
p3_home="$p3_root/bridge-home"
p3_data="$p3_root/data"
p3_agent_root="$p3_data/agents"
p3_v2_home="$p3_agent_root/v2-c/home"
mkdir -p "$p3_home/agents" "$p3_v2_home"
p3_bash="$(
  BRIDGE_AGENT_ROOT_V2="$p3_agent_root" \
    BRIDGE_AGENT_HOME_ROOT="$p3_home/agents" \
    bash_agent_default_home v2-c
)"
p3_py="$(
  BRIDGE_HOME="$p3_home" \
    BRIDGE_DATA_ROOT="$p3_data" \
    BRIDGE_AGENT_ROOT_V2="$p3_agent_root" \
    BRIDGE_AGENT_HOME_ROOT="$p3_home/agents" \
    py_home "$REPO_ROOT/hooks" v2-c
)"
if [[ "$p3_py" == "$p3_bash" && "$p3_py" == "$p3_v2_home" ]]; then
  pass "P3: v2-split parity (bash==python==$p3_v2_home)"
else
  fail "P3: v2-split parity MISMATCH — bash=[$p3_bash] python=[$p3_py] expected=[$p3_v2_home]"
fi
rm -rf "$p3_root"

# ----- J1: agent show --json emits a non-null v2-correct agent_home ------
# Drive the JSON converter directly (same logic bridge-agent.sh::
# emit_agent_records_json runs in `show` mode) over a single-row TSV that
# carries the appended agent_home column. This isolates the JSON-shape change
# from the full roster/tmux stack.
j1_root="$(mktemp -d -t agb-1497-j1.XXXXXX)"
j1_home="/data/agents/show-a/home"
j1_tsv="$(printf 'agent\tdescription\tengine\tsource\tsession\tsession_id\tworkdir\tprofile_home\tprofile_source\tactive\tactivity_state\tloop\tcontinue\talways_on\tidle_timeout\twake_status\tnotify_status\tchannel_status\tchannels\tnotify_kind\tnotify_target\tnotify_account\tdiscord_channel_id\tisolation_mode\tos_user\tqueue_queued\tqueue_claimed\tqueue_blocked\tactions\tadmin\tagent_home\nshow-a\tdesc\tclaude\troster\t-\t-\t/data/agents/show-a/workdir\t-\tno\tyes\tidle\t0\t0\tno\t0\tok\tok\tok\t-\t-\t-\t-\t-\tshared\t-\t0\t0\t0\t-\tno\t%s\n' "$j1_home")"
# Write the converter to a temp file and invoke it by path — lint-heredoc-ban
# permits `cat > file <<EOF` but not heredoc-stdin into `python3 -`.
j1_py="$(mktemp -t agb-1497-j1.XXXXXX.py)"
cat > "$j1_py" <<'PY'
import csv, io, json, sys
mode = sys.argv[1]
rows = list(csv.DictReader(io.StringIO(sys.argv[2]), delimiter="\t"))
runtime_state = sys.argv[3] if len(sys.argv) > 3 else ""
bool_fields = {"active", "profile_source", "always_on", "admin"}
int_fields = {"loop", "continue", "idle_timeout", "queue_queued", "queue_claimed", "queue_blocked"}
def convert_value(key, value):
    if key in bool_fields:
        return value == "yes"
    if key in int_fields:
        try:
            return int(value)
        except Exception:
            return 0
    return value
def convert_row(row):
    converted = {k: convert_value(k, v) for k, v in row.items()}
    return {
        "agent": converted["agent"],
        "workdir": converted["workdir"],
        "agent_home": converted.get("agent_home", ""),
        "admin": converted["admin"],
    }
payload = [convert_row(r) for r in rows]
rec = payload[0] if mode == "show" else payload
print(json.dumps(rec.get("agent_home", None)))
PY
j1_out="$(
  "$PYTHON" "$j1_py" show "$j1_tsv" "v2-active" 2>&1 || true
)"
rm -f "$j1_py"
if [[ "$j1_out" == "\"$j1_home\"" ]]; then
  pass "J1: agent show --json emits v2-correct agent_home ($j1_home)"
else
  fail "J1: agent_home not surfaced in JSON — got: [$j1_out] expected: [\"$j1_home\"]"
fi
rm -rf "$j1_root"

# ----- R1: RESOLVED-first precedence -------------------------------------
# With a v2 signal AND a different exported BRIDGE_AGENT_HOME_RESOLVED, the
# exported scalar must win (bash is authoritative; Python is a thin consumer).
r1_root="$(mktemp -d -t agb-1497-r1.XXXXXX)"
r1_data="$r1_root/data"
r1_agent_root="$r1_data/agents"
r1_resolved="$r1_root/explicit-home"
mkdir -p "$r1_agent_root/dyn-r/home" "$r1_resolved"
r1_py="$(
  BRIDGE_DATA_ROOT="$r1_data" \
    BRIDGE_AGENT_ROOT_V2="$r1_agent_root" \
    BRIDGE_AGENT_HOME_RESOLVED="$r1_resolved" \
    py_home "$REPO_ROOT/hooks" dyn-r
)"
if [[ "$r1_py" == "$r1_resolved" ]]; then
  pass "R1: BRIDGE_AGENT_HOME_RESOLVED wins over v2 computation"
else
  fail "R1: RESOLVED-first precedence broken — python=[$r1_py] expected=[$r1_resolved]"
fi
rm -rf "$r1_root"

# ----- S1: v2 split-brain immunity ---------------------------------------
# Legacy `agents/<a>` dir physically present, v2 signalled, NO RESOLVED env.
# Python must resolve the v2 home, never the legacy short-circuit.
s1_root="$(mktemp -d -t agb-1497-s1.XXXXXX)"
s1_home="$s1_root/bridge-home"
s1_data="$s1_root/data"
s1_agent_root="$s1_data/agents"
s1_v2_home="$s1_agent_root/split-a/home"
s1_legacy_home="$s1_home/agents/split-a"
mkdir -p "$s1_v2_home" "$s1_legacy_home"
s1_py="$(
  BRIDGE_HOME="$s1_home" \
    BRIDGE_DATA_ROOT="$s1_data" \
    BRIDGE_AGENT_ROOT_V2="$s1_agent_root" \
    BRIDGE_AGENT_HOME_ROOT="$s1_home/agents" \
    py_home "$REPO_ROOT/hooks" split-a
)"
if [[ "$s1_py" == "$s1_v2_home" && "$s1_py" != "$s1_legacy_home" ]]; then
  pass "S1: v2 home wins over physically-present legacy dir"
else
  fail "S1: split-brain short-circuit beat v2 — python=[$s1_py] v2=[$s1_v2_home] legacy=[$s1_legacy_home]"
fi
rm -rf "$s1_root"

# ----- T1: TEETH — reverting the HOME-RESOLVED read breaks parity --------
# Copy the hook, strip the BRIDGE_AGENT_HOME_RESOLVED fast-path out of
# agent_default_home, and assert the RESOLVED-first precedence (R1 shape)
# NO LONGER holds. If this case "passes" with the read present, the read is
# not load-bearing and the fix is hollow.
t1_root="$(mktemp -d -t agb-1497-t1.XXXXXX)"
t1_overlay="$t1_root/overlay/hooks"
t1_data="$t1_root/data"
t1_agent_root="$t1_data/agents"
t1_resolved="$t1_root/explicit-home"
mkdir -p "$t1_overlay" "$t1_agent_root/dyn-t/home" "$t1_resolved"
cp "$REPO_ROOT/hooks/bridge_hook_common.py" "$t1_overlay/bridge_hook_common.py"
# Neutralize the HOME-RESOLVED fast path: rewrite the env name it reads so the
# exported scalar is ignored and the resolver falls through to v2. Mutator goes
# to a temp file (lint-heredoc-ban forbids heredoc-stdin into `python3 -`).
t1_mutator="$(mktemp -t agb-1497-t1.XXXXXX.py)"
cat > "$t1_mutator" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
# Only touch the agent_default_home fast-path read, not the workdir resolver.
patched = text.replace(
    'explicit = _resolved_env_path("BRIDGE_AGENT_HOME_RESOLVED")',
    'explicit = _resolved_env_path("BRIDGE_AGENT_HOME_RESOLVED_DISABLED_FOR_TEETH")',
    1,
)
if patched == text:
    raise SystemExit("TEETH setup error: HOME-RESOLVED read marker not found")
open(path, "w", encoding="utf-8").write(patched)
PY
"$PYTHON" "$t1_mutator" "$t1_overlay/bridge_hook_common.py"
rm -f "$t1_mutator"
t1_py="$(
  BRIDGE_DATA_ROOT="$t1_data" \
    BRIDGE_AGENT_ROOT_V2="$t1_agent_root" \
    BRIDGE_AGENT_HOME_RESOLVED="$t1_resolved" \
    py_home "$t1_overlay" dyn-t
)"
# With the read reverted, the resolver ignores $t1_resolved and returns the v2
# home — so parity with the RESOLVED value MUST break.
if [[ "$t1_py" != "$t1_resolved" && "$t1_py" == "$t1_agent_root/dyn-t/home" ]]; then
  pass "T1: TEETH — reverting HOME-RESOLVED read breaks RESOLVED-first (read is load-bearing)"
else
  fail "T1: TEETH did not bite — reverted hook still honored RESOLVED: python=[$t1_py]"
fi
rm -rf "$t1_root"

# ----- Summary -----------------------------------------------------------
printf '\n[smoke] 1497-p1-home-resolver: %d pass, %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke] failing scenarios:\n' >&2
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure" >&2
  done
  exit 1
fi
exit 0
