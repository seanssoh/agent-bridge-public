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
#   D2  bridge_refresh_agent_session_id() (lib/bridge-state.sh): same non-assoc
#       failure on BRIDGE_AGENT_CREATED_AT via the `since_hint` read.
#   D3  process_a2a_outbox_stuck_scan_tick() (bridge-daemon.sh): markdown-bullet
#       `printf '- ...'` lines — bash printf parses the leading `-` as an option
#       → `printf: - : invalid option`.
#
# This smoke asserts the post-fix behavior, under `set -u`, with the
# associative arrays UNSET:
#   (a) D1/D2 degrade to empty / date-default with NO `unbound variable` abort;
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

# --- D2: bridge_refresh_agent_session_id `since_hint` declare-guard ----------
# The since_hint read of BRIDGE_AGENT_CREATED_AT (lib/bridge-state.sh) is the
# #1407 D2 site. We pin the fixed branch directly: the full surrounding function
# walks BRIDGE_AGENT_IDS and a long detect/persist plumbing chain that is not
# the regression target and is awkward to stub deterministically, so the assert
# below exercises ONLY the declare-guard the fix added — the exact lines that,
# pre-fix, arithmetic-indexed the agent id under `set -u` and aborted with
# `<agent>: unbound variable`. A source-presence guard (D2-src) additionally
# confirms the guarded form is the one that ships in lib/bridge-state.sh.
d2_out="$(
	"$BASH4" -c '
		set -u
		unset BRIDGE_AGENT_CREATED_AT 2>/dev/null || true
		agent="some-agent"
		if declare -p BRIDGE_AGENT_CREATED_AT 2>/dev/null | grep -q "declare -[A-Za-z]*A"; then
			since_hint="${BRIDGE_AGENT_CREATED_AT[$agent]-$(date +%s)}"
		else
			since_hint="$(date +%s)"
		fi
		printf "SINCE=[%s]\n" "$since_hint"
	' 2>&1
)" || true
printf '%s\n' "$d2_out"
if printf '%s' "$d2_out" | grep -q 'unbound variable'; then
	fail "D2 since_hint declare-guard aborted with 'unbound variable' on unset assoc array"
elif printf '%s' "$d2_out" | grep -qE 'SINCE=\[[0-9]+\]'; then
	pass "D2 since_hint declare-guard yields a numeric date-default on unset assoc array (no abort)"
else
	fail "D2 since_hint declare-guard did not yield a numeric fallback"
fi

# --- D2-src: the guarded since_hint form is what ships in lib/bridge-state.sh -
if grep -q "declare -p BRIDGE_AGENT_CREATED_AT" "$SCRIPT_DIR/lib/bridge-state.sh"; then
	pass "D2-src lib/bridge-state.sh contains the BRIDGE_AGENT_CREATED_AT declare-guard"
else
	fail "D2-src lib/bridge-state.sh missing the BRIDGE_AGENT_CREATED_AT declare-guard"
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
