#!/usr/bin/env bash
# smoke/1407-runtime-hardening.sh — runtime-hardening regression guard for #1407.
#
# #1407 (Mejurix) reported three independent surface aborts that fire when an
# install is in the empty-session + continue=1 state (the resume-gate root is
# tracked separately at #1248/#1264/#1265/#1277 — NOT this smoke's concern):
#
#   D1  bridge_agent_session_id()  (lib/bridge-agents.sh): indexed read of
#       BRIDGE_AGENT_SESSION_ID when it is not an associative array (unset /
#       clobbered to scalar) → arithmetic-indexes the agent id under `set -u`
#       → `<agent>: unbound variable` abort.
#   D1b bridge_agent_engine() / bridge_agent_workdir() (lib/bridge-agents.sh):
#       the same non-assoc map read class on BRIDGE_AGENT_ENGINE and
#       BRIDGE_AGENT_WORKDIR.
#   D2  created-at indexed reads of BRIDGE_AGENT_CREATED_AT — same non-assoc
#       failure as D1. Originally surfaced via bridge_refresh_agent_session_id's
#       `since_hint` read; codex (PR #1410 r1) found the detect->persist path
#       (bridge_write_agent_state_file) carried the same unguarded read. All
#       such reads now route through ONE central guarded accessor,
#       bridge_agent_created_at() (lib/bridge-agents.sh).
#   D3  process_a2a_outbox_stuck_scan_tick() (bridge-daemon.sh): markdown-bullet
#       `printf '- ...'` lines — bash printf parses the leading `-` as an option
#       → `printf: - : invalid option`.
#
# This smoke asserts the post-fix behavior, under `set -u`, with the
# associative arrays UNSET:
#   (a) D1/D1b/D2 degrade to empty / unknown / default with NO abort;
#   (b) D3 emits the literal `- ...` bullets with NO `invalid option`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

# Agent Bridge requires bash 4+ (the lib uses associative arrays, `[[ -v
# arr[k] ]]`, and empty-array `"${arr[@]}"` under `set -u`). The macOS system
# bash is 3.2, so resolve a bash >= 4 the same contract the runtime relies on
# (PATH-first, then the usual Homebrew locations) and run the sourced-library
# subshells under it. Falls back to PATH `bash` (which is 4+ on Linux CI).
resolve_bash4() {
	local cand
	for cand in \
		"${BRIDGE_BASH_BIN:-}" \
		"$(command -v bash 2>/dev/null || true)" \
		/opt/homebrew/bin/bash \
		/usr/local/bin/bash \
		/bin/bash; do
		[[ -n "$cand" && -x "$cand" ]] || continue
		if "$cand" -c '((BASH_VERSINFO[0] >= 4))' 2>/dev/null; then
			printf '%s' "$cand"
			return 0
		fi
	done
	# Last resort: PATH bash (let the assertion surface a real failure rather
	# than masking it with a 3.2-only `unbound variable` artifact).
	printf 'bash'
}
BASH4="$(resolve_bash4)"

# --- D1: bridge_agent_session_id with assoc array UNSET ----------------------
# Run in a fresh `bash -c` so the `declare -gA` from the sourced libs can be
# undone with `unset` and the function exercised under `set -u` in isolation.
d1_out="$(
	"$BASH4" -c '
		set -u
		source "'"$SCRIPT_DIR"'/lib/bridge-core.sh" 2>/dev/null || true
		source "'"$SCRIPT_DIR"'/lib/bridge-state.sh" 2>/dev/null || true
		source "'"$SCRIPT_DIR"'/lib/bridge-agents.sh" 2>/dev/null || true
		# Clobber: make the assoc array truly absent.
		unset BRIDGE_AGENT_SESSION_ID 2>/dev/null || true
		# Stub the loader so the function does not re-create the array.
		bridge_load_agent_state_once() { :; }
		result="$(bridge_agent_session_id some-agent)"
		printf "D1_RESULT=[%s]\n" "$result"
	' 2>&1
)" || true
printf '%s\n' "$d1_out"
if printf '%s' "$d1_out" | grep -q 'unbound variable'; then
	fail "D1 bridge_agent_session_id aborted with 'unbound variable' on unset assoc array"
elif printf '%s' "$d1_out" | grep -q 'D1_RESULT=\[\]'; then
	pass "D1 bridge_agent_session_id degrades to empty on unset assoc array (no abort)"
else
	fail "D1 bridge_agent_session_id did not return empty as expected"
fi

# --- D1b: BRIDGE_AGENT_ENGINE/WORKDIR unset or scalar-clobbered --------------
# The 2026-06-01 Telegram wedge RCA found two more #1407-class reads:
# bridge_agent_engine and bridge_agent_workdir indexed their maps directly under
# `set -u`. Engine must degrade to unknown. Workdir must ignore the invalid
# explicit map and continue through the existing default resolver.
d1b_out="$(
	"$BASH4" -c '
		set -u
		source "'"$SCRIPT_DIR"'/lib/bridge-core.sh" 2>/dev/null || true
		source "'"$SCRIPT_DIR"'/lib/bridge-state.sh" 2>/dev/null || true
		source "'"$SCRIPT_DIR"'/lib/bridge-agents.sh" 2>/dev/null || true
		BRIDGE_AGENT_ROOT_V2=
		BRIDGE_AGENT_HOME_ROOT="/tmp/agb-1407-home"
		unset BRIDGE_AGENT_ENGINE BRIDGE_AGENT_WORKDIR 2>/dev/null || true
		printf "D1B_ENGINE_UNSET=[%s]\n" "$(bridge_agent_engine some-agent)"
		printf "D1B_WORKDIR_UNSET=[%s]\n" "$(bridge_agent_workdir some-agent)"
		BRIDGE_AGENT_ENGINE=scalar
		BRIDGE_AGENT_WORKDIR=scalar
		printf "D1B_ENGINE_SCALAR=[%s]\n" "$(bridge_agent_engine some-agent)"
		printf "D1B_WORKDIR_SCALAR=[%s]\n" "$(bridge_agent_workdir some-agent)"
	' 2>&1
)" || true
printf '%s\n' "$d1b_out"
if printf '%s' "$d1b_out" | grep -q 'unbound variable'; then
	fail "D1b bridge_agent_engine/workdir aborted with 'unbound variable' on unset/scalar maps"
elif printf '%s' "$d1b_out" | grep -q 'D1B_ENGINE_UNSET=\[unknown\]' \
	&& printf '%s' "$d1b_out" | grep -q 'D1B_ENGINE_SCALAR=\[unknown\]' \
	&& printf '%s' "$d1b_out" | grep -q 'D1B_WORKDIR_UNSET=\[/tmp/agb-1407-home/some-agent\]' \
	&& printf '%s' "$d1b_out" | grep -q 'D1B_WORKDIR_SCALAR=\[/tmp/agb-1407-home/some-agent\]'; then
	pass "D1b bridge_agent_engine/workdir tolerate unset and scalar-clobbered maps"
else
	fail "D1b bridge_agent_engine/workdir did not return the expected fallback values"
fi

# --- D2-accessor: bridge_agent_created_at degrades to default on non-assoc ----
# The #1407 D2 created-at reads now route through ONE central guarded accessor
# (bridge_agent_created_at, lib/bridge-agents.sh). codex (PR #1410 r1) showed
# the original per-site guard was incomplete (the detect->persist path stayed
# unguarded), so we now assert the accessor's behavior directly: with
# BRIDGE_AGENT_CREATED_AT clobbered to a scalar under `set -u`, it must return
# the caller default instead of aborting with `<agent>: unbound variable`.
d2acc_out="$(
	"$BASH4" -c '
		set -u
		source "'"$SCRIPT_DIR"'/lib/bridge-core.sh" 2>/dev/null || true
		source "'"$SCRIPT_DIR"'/lib/bridge-state.sh" 2>/dev/null || true
		source "'"$SCRIPT_DIR"'/lib/bridge-agents.sh" 2>/dev/null || true
		unset BRIDGE_AGENT_CREATED_AT 2>/dev/null || true
		BRIDGE_AGENT_CREATED_AT=scalar
		printf "D2ACC=[%s]\n" "$(bridge_agent_created_at some-agent 99)"
	' 2>&1
)" || true
printf '%s\n' "$d2acc_out"
if printf '%s' "$d2acc_out" | grep -q 'unbound variable'; then
	fail "D2-accessor bridge_agent_created_at aborted with 'unbound variable' on non-assoc map"
elif printf '%s' "$d2acc_out" | grep -q 'D2ACC=\[99\]'; then
	pass "D2-accessor bridge_agent_created_at degrades to caller default on non-assoc map (no abort)"
else
	fail "D2-accessor bridge_agent_created_at did not return the caller default"
fi

# --- D2-persist: codex's exact repro — the detect->persist created-at read ----
# bridge_write_agent_state_file (lib/bridge-state.sh) is reached via
# bridge_refresh_agent_session_id -> bridge_persist_agent_state on a successful
# detect. Pre-fix it carried an UNGUARDED `${BRIDGE_AGENT_CREATED_AT[$agent]-…}`
# read that still aborted on the same non-assoc state D2 is meant to tolerate.
# Drive that function directly under a scalar-clobbered map; pre-fix signature
# is `<agent>: unbound variable`.
d2per_out="$(
	"$BASH4" -c '
		set -u
		source "'"$SCRIPT_DIR"'/lib/bridge-core.sh" 2>/dev/null || true
		source "'"$SCRIPT_DIR"'/lib/bridge-state.sh" 2>/dev/null || true
		source "'"$SCRIPT_DIR"'/lib/bridge-agents.sh" 2>/dev/null || true
		bridge_reset_roster_maps 2>/dev/null || true
		agent=some-agent
		BRIDGE_AGENT_IDS=("$agent")
		BRIDGE_AGENT_DESC["$agent"]="$agent"
		BRIDGE_AGENT_ENGINE["$agent"]="claude"
		BRIDGE_AGENT_SESSION["$agent"]="sess"
		BRIDGE_AGENT_WORKDIR["$agent"]="/tmp"
		BRIDGE_AGENT_SOURCE["$agent"]="static"
		BRIDGE_AGENT_LOOP["$agent"]="1"
		BRIDGE_AGENT_CONTINUE["$agent"]="1"
		BRIDGE_AGENT_SESSION_ID["$agent"]="sid"
		unset BRIDGE_AGENT_CREATED_AT
		BRIDGE_AGENT_CREATED_AT=scalar
		bridge_write_agent_state_file "$agent" "$(mktemp "${TMPDIR:-/tmp}/agb-1407-state.XXXXXX")" \
			&& printf "D2PER=ok\n"
	' 2>&1
)" || true
printf '%s\n' "$d2per_out"
if printf '%s' "$d2per_out" | grep -q 'unbound variable'; then
	fail "D2-persist bridge_write_agent_state_file aborted on non-assoc CREATED_AT (the r1 BLOCKING site)"
else
	pass "D2-persist bridge_write_agent_state_file tolerates non-assoc CREATED_AT (detect->persist path)"
fi

# --- D2-class: every indexed CREATED_AT read routes through the accessor ------
# The only permitted indexed `BRIDGE_AGENT_CREATED_AT[$agent]-` read is the
# accessor's own `-$default_val}` form (behind its declare-guard). Any other is
# an unguarded reintroduction of the #1407 D2 abort class.
d2cls_hits="$(
	grep -rnF 'BRIDGE_AGENT_CREATED_AT[$agent]-' \
		"$SCRIPT_DIR/lib/bridge-agents.sh" \
		"$SCRIPT_DIR/lib/bridge-state.sh" \
		"$SCRIPT_DIR/bridge-sync.sh" 2>/dev/null \
	| grep -vF -- '-$default_val}' || true
)"
if [ -z "$d2cls_hits" ]; then
	pass "D2-class all indexed CREATED_AT reads route through the guarded accessor"
else
	fail "D2-class unguarded indexed CREATED_AT reads remain:"
	printf '%s\n' "$d2cls_hits"
fi

# --- D2-dynload: codex (PR #1410 r2) found the static-collision branch of -----
# bridge_load_dynamic_agent_file STILL aborts on a scalar-clobbered roster map.
# That branch does an assoc WRITE `BRIDGE_AGENT_CREATED_AT["$AGENT_ID"]=…` — and
# empirically the WRITE itself aborts on a scalar map, so routing only the RHS
# read through the accessor is NOT enough. The fix repairs any clobbered map back
# to associative (bridge_ensure_roster_maps_assoc) right after `source "$file"`.
# This drives codex's EXACT repro through the real loader; pre-fix signature is
# `<id>: unbound variable`.
#
# Source the granular libs (core+state+agents) like D2-accessor/D2-persist above,
# NOT the full bridge-lib.sh: in a markerless CI/test home, bridge-lib.sh's
# isolation-v2 layout gate (v0.8.0) `exit`s before bridge_load_dynamic_agent_file
# is defined, so the loader would never run and D2DYN would be blank. The granular
# libs define the loader + bridge_reset_roster_maps + bridge_ensure_roster_maps_assoc
# + bridge_add_agent_id_if_missing without tripping the layout resolver. (codex
# PR #1412 r1 caught this CI-only fixture bug; reproduced markerless on Ubuntu.)
d2dyn_out="$(
	"$BASH4" -c '
		set -u
		source "'"$SCRIPT_DIR"'/lib/bridge-core.sh" 2>/dev/null || true
		source "'"$SCRIPT_DIR"'/lib/bridge-state.sh" 2>/dev/null || true
		source "'"$SCRIPT_DIR"'/lib/bridge-agents.sh" 2>/dev/null || true
		bridge_reset_roster_maps 2>/dev/null || true
		agent=some-agent
		bridge_add_agent_id_if_missing "$agent"
		BRIDGE_AGENT_SOURCE["$agent"]="static"
		BRIDGE_AGENT_ENGINE["$agent"]="claude"
		BRIDGE_AGENT_SESSION["$agent"]="sess"
		BRIDGE_AGENT_WORKDIR["$agent"]="/tmp"
		BRIDGE_AGENT_SESSION_ID["$agent"]=""
		unset BRIDGE_AGENT_CREATED_AT
		BRIDGE_AGENT_CREATED_AT=scalar
		bridge_resolve_resume_session_id() { printf ""; return 1; }
		f="$(mktemp "${TMPDIR:-/tmp}/agb-1407-dyn.XXXXXX")"
		printf "%s\n" "AGENT_ID=$agent" "AGENT_ENGINE=claude" "AGENT_SESSION=sess2" "AGENT_WORKDIR=/tmp" >"$f"
		bridge_load_dynamic_agent_file "$f" && printf "D2DYN=ok\n"
		rm -f "$f"
	' 2>&1
)" || true
printf '%s\n' "$d2dyn_out"
if printf '%s' "$d2dyn_out" | grep -q 'unbound variable'; then
	fail "D2-dynload bridge_load_dynamic_agent_file aborted on scalar-clobbered roster map (codex r2 site)"
elif printf '%s' "$d2dyn_out" | grep -q 'D2DYN=ok'; then
	pass "D2-dynload bridge_load_dynamic_agent_file tolerates scalar-clobbered roster map (static-collision branch)"
else
	fail "D2-dynload did not reach the loaded-ok marker: $d2dyn_out"
fi

# --- D2-repair: the loader must repair clobbered maps right after `source` -----
# Static-presence guard for the fix above: bridge_load_dynamic_agent_file calls
# bridge_ensure_roster_maps_assoc, and the helper redeclares (not just reads).
if grep -q 'bridge_ensure_roster_maps_assoc' "$SCRIPT_DIR/lib/bridge-state.sh" \
	&& grep -q 'declare -gA "\$_m=()"' "$SCRIPT_DIR/lib/bridge-state.sh"; then
	pass "D2-repair bridge_ensure_roster_maps_assoc present + redeclares maps in lib/bridge-state.sh"
else
	fail "D2-repair bridge_ensure_roster_maps_assoc missing or does not redeclare maps"
fi

# --- D3: stuck-scan markdown bullets emit literal `- ...` (no invalid option) -
# Exercise the exact printf form used by process_a2a_outbox_stuck_scan_tick.
d3_out="$(
	"$BASH4" -c '
		set -u
		printf -- "- message_id: %s\n" "M1"
		printf -- "- title: %s\n"      "T1"
		printf -- "- to: %s\n"         "peer"
		printf -- "- attempts: %s\n"   "3"
		printf -- "- created_at: %s\n" "0"
		printf -- "- next_retry_at: %s\n" "0"
		printf -- "- last_error: %s\n" "boom"
	' 2>&1
)" || true
printf '%s\n' "$d3_out"
if printf '%s' "$d3_out" | grep -q 'invalid option'; then
	fail "D3 stuck-scan printf emitted 'invalid option' (leading-dash regression)"
elif printf '%s' "$d3_out" | grep -q '^- message_id: M1$' \
	&& printf '%s' "$d3_out" | grep -q '^- last_error: boom$'; then
	pass "D3 stuck-scan printf emits literal '- ...' bullets (printf -- form)"
else
	fail "D3 stuck-scan printf did not emit the expected literal bullets"
fi

# --- D3b: verify the real bridge-daemon.sh source has no bare `printf '- ` ----
if grep -q "printf '- " "$SCRIPT_DIR/bridge-daemon.sh"; then
	fail "D3b bridge-daemon.sh still contains a bare \"printf '- \" (leading-dash) site"
else
	pass "D3b bridge-daemon.sh contains no bare \"printf '- \" leading-dash sites"
fi

# --- summary -----------------------------------------------------------------
printf '\n--- 1407 smoke: %d passed, %d failed (bash %s) ---\n' \
	"$PASS" "$FAIL" "$("$BASH4" -c 'printf %s "$BASH_VERSION"')"
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0
