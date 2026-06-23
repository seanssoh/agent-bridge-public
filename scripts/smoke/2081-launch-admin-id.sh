#!/usr/bin/env bash
# scripts/smoke/2081-launch-admin-id.sh — #2081 receiver-launch fail-open fix.
#
# The #2079 cross-node admin↔admin authz predicate recomputes a LOCAL endpoint's
# admin status from $BRIDGE_ADMIN_AGENT_ID. The receiver LAUNCH paths did NOT
# provide it (the systemd handoffd unit runs with only BRIDGE_HOME; `agb a2a
# daemon start` / `bridge-handoff-daemon.sh start` reach the spawn through a
# dispatcher that never sources the roster), so a LOCAL admin classified UNKNOWN
# and a `non-admin@remote -> admin@local` cross-node delivery FAILED OPEN
# (allowed as not_admin_involved instead of denied as sender_not_admin).
#
# This smoke proves the launch-path RESOLUTION fix in the exact lifecycle/systemd
# shape — the admin id present ONLY in the on-disk roster, NOT in the process env
# — over TWO real launch resolvers:
#   Part 1 (Python): rooms.ensure_admin_agent_id_in_env() — the resolver
#     bridge-handoffd.py serve calls at startup (covers the systemd unit, which
#     runs the python entrypoint directly). Mutation-proven: env-unset -> ALLOW
#     (pre-fix fail-open); resolver-applied -> DENY.
#   Part 2 (shell): bridge_a2a_export_admin_agent_id (lib/bridge-a2a.sh) — the
#     export the `agb a2a daemon start|restart` / `bridge-handoff-daemon.sh
#     start` paths run before the spawn. Asserts it populates the env from the
#     on-disk roster with the var initially unset.
#
# ISOLATION: an isolated BRIDGE_HOME (smoke_setup_bridge_home), the test-bind
# flag for the in-process rooms.db opens. NEVER ticks the live runtime; NEVER
# sets BRIDGE_ALLOW_FOREIGN_CHECKOUT; NEVER spawns a real listener.

set -euo pipefail

# Each launch-shape probe runs the export helper inside its OWN $(...) subshell
# so the BRIDGE_ADMIN_AGENT_ID it sets cannot leak between probes — that
# isolation is the intent, not a bug. Disabled file-wide (info-severity; matches
# the existing smoke convention, e.g. 2030-wedge-sleep-aware-deadline.sh).
# shellcheck disable=SC2030,SC2031
SMOKE_NAME="2081-launch-admin-id"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/2081-launch-admin-id-helper.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

ADMIN_ID="padmin"

# Persist the configured admin id to the on-disk roster EXACTLY as
# bridge-setup.sh does (`bridge_setup_write_local_scalar BRIDGE_ADMIN_AGENT_ID`
# -> `BRIDGE_ADMIN_AGENT_ID="<value>"`). The value lives ONLY on disk; we never
# export it into the process env — that is the whole point.
cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_ADMIN_AGENT_ID="$ADMIN_ID"
EOF

# Belt-and-braces: the var must NOT be in this shell's environment. If the
# operator's shell or smoke_setup leaked it, drop it so the launch-shape
# precondition holds and the mutation proof is real.
unset BRIDGE_ADMIN_AGENT_ID

# ---------------------------------------------------------------------------
# Part 1 — Python startup resolver (the systemd-unit / serve-entrypoint path).
# ---------------------------------------------------------------------------
smoke_log "setup/act/assert: env-unset launch — Python startup resolver (rooms.ensure_admin_agent_id_in_env) DENIES non-admin@remote -> admin@local"
# SMOKE_ROSTER_FILE / SMOKE_SHARED_ROSTER_FILE let the helper REWRITE the local
# and shared rosters in-place for the F1/F2/F3/F4 teeth (stale-last-assignment,
# unreadable-file fail-close, malformed-value fail-close, blank-local-stops-
# fallthrough); they are the SAME files the env-unset launch shape resolves from.
LAUNCH_OUT="$(BRIDGE_A2A_ALLOW_TEST_BIND=1 SMOKE_EXPECT_ADMIN_ID="$ADMIN_ID" \
  SMOKE_ROSTER_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
  SMOKE_SHARED_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
  python3 "$HELPER" 2>&1)" || true
printf '%s\n' "$LAUNCH_OUT"
smoke_assert_contains "$LAUNCH_OUT" "OVERALL PASS" \
  "the env-unset launch authz teeth all pass"
for t in precondition_admin_id_absent_from_env \
         precondition_admin_id_resolvable_from_disk \
         mutation_off_unresolved_env_is_failopen \
         resolver_populated_env_from_disk \
         launch_resolution_denies_nonadmin_to_admin \
         resolver_env_first_does_not_clobber \
         f2_last_assignment_wins_over_stale_export \
         f1_unreadable_roster_failcloses \
         f1_ensure_env_propagates_resolve_error \
         f1_readable_no_admin_still_open \
         f3_malformed_unbalanced_quote_failcloses \
         f3_malformed_invalid_charset_failcloses \
         f3_malformed_junk_after_close_quote_failcloses \
         f3_malformed_bare_hash_not_comment_failcloses \
         f3_malformed_extra_bare_words_failcloses \
         f3_malformed_hash_fused_after_quote_failcloses \
         f3_malformed_plus_equals_append_failcloses \
         f3_malformed_mixed_quote_concat_failcloses \
         f3_malformed_command_substitution_failcloses \
         f4_blank_local_stops_fallthrough \
         f4_no_local_assignment_falls_through_to_shared \
         f5_leading_ws_space_after_eq_is_empty \
         f5_leading_ws_tab_after_eq_is_empty \
         f5_leading_ws_space_before_quote_is_empty \
         f5_leading_ws_local_stops_fallthrough; do
  smoke_assert_contains "$LAUNCH_OUT" "RESULT $t PASS" "tooth $t green"
done

# The helper rewrote the SHARED roster for its F4 teeth; clear it so Part 2's
# shell-launch teeth resolve only from the local roster.
: >"$BRIDGE_ROSTER_FILE"

# The helper rewrote the roster for its F1/F2 teeth; restore the canonical
# admin-id roster for the shell-launch teeth in Part 2 below.
cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_ADMIN_AGENT_ID="$ADMIN_ID"
EOF
smoke_log "ok: env-unset launch — Python startup resolver DENIES non-admin@remote -> admin@local (mutation-proven against the pre-fix fail-open)"

# ---------------------------------------------------------------------------
# Part 2 — shell export helper (the `agb a2a daemon start|restart` path).
# Source the lib in a sub-shell with the var unset and assert the helper
# resolves+exports it from the on-disk roster. A node WITHOUT a configured admin
# must NOT have the var forced (it must stay unset → local endpoints UNKNOWN →
# non-admin traffic stays open; only an admin-claimed counterpart fail-closes).
# ---------------------------------------------------------------------------
smoke_log "setup/act/assert: shell launch — bridge_a2a_export_admin_agent_id resolves+exports the admin id from the on-disk roster"
SHELL_RESOLVED="$(
  unset BRIDGE_ADMIN_AGENT_ID
  # shellcheck source=lib/bridge-a2a.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
  bridge_a2a_export_admin_agent_id
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-<unset>}"
)"
smoke_assert_eq "$ADMIN_ID" "$SHELL_RESOLVED" \
  "shell launch helper exports the configured admin id from agent-roster.local.sh"

smoke_log "setup/act/assert: shell launch — env-first precedence: a pre-set value is NOT clobbered by a stale on-disk read"
SHELL_PRESET="$(
  export BRIDGE_ADMIN_AGENT_ID="preset_from_run_env"
  # shellcheck source=lib/bridge-a2a.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
  bridge_a2a_export_admin_agent_id
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-<unset>}"
)"
smoke_assert_eq "preset_from_run_env" "$SHELL_PRESET" \
  "shell launch helper keeps an already-exported admin id (env-first)"

smoke_log "setup/act/assert: shell launch — F2: a stale earlier assignment is overridden by the LAST (bash source semantics)"
cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
export BRIDGE_ADMIN_AGENT_ID="old_admin"
BRIDGE_ADMIN_AGENT_ID="$ADMIN_ID"
EOF
SHELL_STALE="$(
  unset BRIDGE_ADMIN_AGENT_ID
  # shellcheck source=lib/bridge-a2a.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
  bridge_a2a_export_admin_agent_id
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-<unset>}"
)"
smoke_assert_eq "$ADMIN_ID" "$SHELL_STALE" \
  "shell launch helper takes the LAST roster assignment, not a stale earlier export (F2)"

smoke_log "setup/act/assert: shell launch — a node with NO configured admin leaves the var unset (non-admin traffic stays open)"
: >"$BRIDGE_ROSTER_LOCAL_FILE"
SHELL_NOADMIN="$(
  unset BRIDGE_ADMIN_AGENT_ID
  # shellcheck source=lib/bridge-a2a.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
  bridge_a2a_export_admin_agent_id
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-<unset>}"
)"
smoke_assert_eq "<unset>" "$SHELL_NOADMIN" \
  "shell launch helper leaves the var unset when no admin is configured (no blanket fail-closed)"

smoke_log "setup/act/assert: shell launch — F3: a malformed (unbalanced-quote) value is NOT exported as garbage"
printf '#!/usr/bin/env bash\nBRIDGE_ADMIN_AGENT_ID="%s\n' "$ADMIN_ID" >"$BRIDGE_ROSTER_LOCAL_FILE"
SHELL_MALFORMED="$(
  unset BRIDGE_ADMIN_AGENT_ID
  # shellcheck source=lib/bridge-a2a.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
  bridge_a2a_export_admin_agent_id
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-<unset>}"
)"
smoke_assert_eq "<unset>" "$SHELL_MALFORMED" \
  "shell launch helper refuses to export a malformed/truncated admin value (F3; Python serve gate fail-closes)"

smoke_log "setup/act/assert: shell launch — F3b: junk fused to the value is NOT truncated to a valid-looking id"
# `"padmin"evil`/`padmin#evil`/`"padmin"#evil` (bash concat) and `pa"d"min`
# (adjacent-quote concat) and `+=padmin` (append) must NOT resolve to `padmin`
# — the shell helper must leave the var unset (round-3 + r5 review).
for bad in '"padmin"evil' 'padmin#evil' 'padmin evil' '"padmin"#evil' 'pa"d"min' '+=padmin'; do
  if [[ "$bad" == '+=padmin' ]]; then
    printf '#!/usr/bin/env bash\nBRIDGE_ADMIN_AGENT_ID+=padmin\n' >"$BRIDGE_ROSTER_LOCAL_FILE"
  else
    printf '#!/usr/bin/env bash\nBRIDGE_ADMIN_AGENT_ID=%s\n' "$bad" >"$BRIDGE_ROSTER_LOCAL_FILE"
  fi
  got="$(
    unset BRIDGE_ADMIN_AGENT_ID
    # shellcheck source=lib/bridge-a2a.sh
    source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
    bridge_a2a_export_admin_agent_id
    printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-<unset>}"
  )"
  smoke_assert_eq "<unset>" "$got" \
    "shell launch helper does not truncate a malformed value ($bad) to a valid-looking id (F3b)"
done

smoke_log "setup/act/assert: shell launch — F3c: a command-substitution value is NOT executed (zero-eval property)"
# The pure parser must NEVER execute a `$(...)` in a roster value. Prove no
# side-effect file is created and the var stays unset.
SENTINEL="$SMOKE_TMP_ROOT/2081-no-exec-sentinel"
rm -f "$SENTINEL"
printf '#!/usr/bin/env bash\nBRIDGE_ADMIN_AGENT_ID="$(touch %s; echo PWNED)"\n' "$SENTINEL" >"$BRIDGE_ROSTER_LOCAL_FILE"
SHELL_CMDSUBST="$(
  unset BRIDGE_ADMIN_AGENT_ID
  # shellcheck source=lib/bridge-a2a.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
  bridge_a2a_export_admin_agent_id
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-<unset>}"
)"
smoke_assert_eq "<unset>" "$SHELL_CMDSUBST" \
  "shell launch helper rejects a command-substitution value (does not export it)"
if [[ -e "$SENTINEL" ]]; then
  smoke_fail "F3c: a command-substitution roster value was EXECUTED (sentinel created) — the parser must never eval roster content"
fi

smoke_log "setup/act/assert: shell launch — F5: leading whitespace after '=' yields an EMPTY value (var stays unset), never the trailing word"
# `KEY= padmin` / `KEY=<tab>padmin` / `KEY= "padmin"` all assign empty in bash.
printf '#!/usr/bin/env bash\nBRIDGE_ADMIN_AGENT_ID= padmin\n' >"$BRIDGE_ROSTER_LOCAL_FILE"
SHELL_WS_SPACE="$(
  unset BRIDGE_ADMIN_AGENT_ID
  # shellcheck source=lib/bridge-a2a.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
  bridge_a2a_export_admin_agent_id
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-<unset>}"
)"
smoke_assert_eq "<unset>" "$SHELL_WS_SPACE" \
  "shell launch helper treats a leading-space RHS as empty, not the trailing word (F5)"
printf '#!/usr/bin/env bash\nBRIDGE_ADMIN_AGENT_ID=\tpadmin\n' >"$BRIDGE_ROSTER_LOCAL_FILE"
SHELL_WS_TAB="$(
  unset BRIDGE_ADMIN_AGENT_ID
  # shellcheck source=lib/bridge-a2a.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
  bridge_a2a_export_admin_agent_id
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-<unset>}"
)"
smoke_assert_eq "<unset>" "$SHELL_WS_TAB" \
  "shell launch helper treats a leading-tab RHS as empty (F5)"

smoke_log "setup/act/assert: shell launch — F4: a present-but-empty LOCAL assignment does NOT fall through to a stale shared admin"
printf 'BRIDGE_ADMIN_AGENT_ID="stale_shared_admin"\n' >"$BRIDGE_ROSTER_FILE"
printf '#!/usr/bin/env bash\nBRIDGE_ADMIN_AGENT_ID=\n' >"$BRIDGE_ROSTER_LOCAL_FILE"
SHELL_BLANK_LOCAL="$(
  unset BRIDGE_ADMIN_AGENT_ID
  # shellcheck source=lib/bridge-a2a.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
  bridge_a2a_export_admin_agent_id
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-<unset>}"
)"
smoke_assert_eq "<unset>" "$SHELL_BLANK_LOCAL" \
  "shell launch helper stops on a present-but-empty local assignment, not the stale shared admin (F4)"

smoke_log "setup/act/assert: shell launch — F4b: NO local assignment falls through to the shared admin (legit)"
printf '#!/usr/bin/env bash\n# local has no admin assignment\n' >"$BRIDGE_ROSTER_LOCAL_FILE"
SHELL_FALLTHROUGH="$(
  unset BRIDGE_ADMIN_AGENT_ID
  # shellcheck source=lib/bridge-a2a.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
  bridge_a2a_export_admin_agent_id
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-<unset>}"
)"
smoke_assert_eq "stale_shared_admin" "$SHELL_FALLTHROUGH" \
  "shell launch helper falls through to the shared admin when the local roster has no assignment (F4b)"
: >"$BRIDGE_ROSTER_FILE"

# ---------------------------------------------------------------------------
# Part 3 — SHARED parity table (#2081 r5-round5 review finding 2). One table
# (scripts/smoke/2081-roster-parse-cases.tsv) of (roster_line, bash-verified
# expected) rows drives BOTH parsers so they stay provably in lock-step:
#   3a) the PYTHON parser via the helper's parity-table mode, and
#   3b) the SHELL parser bridge_a2a_roster_admin_assignment, here.
# A future grammar change in either parser that diverges from bash now fails a
# committed test instead of slipping through.
# ---------------------------------------------------------------------------
CASES_TSV="$SCRIPT_DIR/2081-roster-parse-cases.tsv"
smoke_assert_file_exists "$CASES_TSV" "the shared roster-parse parity table exists"

smoke_log "setup/act/assert: parity table — PYTHON parser matches the bash-verified expected for every row"
PY_PARITY_OUT="$(BRIDGE_A2A_ALLOW_TEST_BIND=1 \
  python3 "$HELPER" parity-table "$CASES_TSV" "$BRIDGE_ROSTER_LOCAL_FILE" 2>&1)" || true
printf '%s\n' "$PY_PARITY_OUT"
smoke_assert_contains "$PY_PARITY_OUT" "OVERALL PASS" \
  "the Python parser matches every parity-table row"

# Shell decoder for the table's \t \v \f \r \n \\ escapes — must match the
# helper's decode_case_line so both write byte-identical roster lines.
decode_case_line() {
  local in="$1" out="" i ch nxt
  for (( i=0; i<${#in}; i++ )); do
    ch="${in:i:1}"
    if [[ "$ch" == "\\" && $((i+1)) -lt ${#in} ]]; then
      nxt="${in:i+1:1}"
      case "$nxt" in
        t) out+=$'\t' ;; v) out+=$'\v' ;; f) out+=$'\f' ;;
        r) out+=$'\r' ;; n) out+=$'\n' ;; '\') out+='\' ;;
        *) out+="\\$nxt" ;;
      esac
      ((i++)); continue
    fi
    out+="$ch"
  done
  printf '%s' "$out"
}

shell_parse_case() {
  local out
  out="$(bridge_a2a_roster_admin_assignment "$BRIDGE_ROSTER_LOCAL_FILE")"
  case "$out" in
    "") printf 'NONE' ;;
    malformed) printf 'MALFORMED' ;;
    found*) printf 'FOUND:%s' "${out#found$'\t'}" ;;
  esac
}

smoke_log "setup/act/assert: parity table — SHELL parser matches the bash-verified expected for every row"
# shellcheck source=lib/bridge-a2a.sh
source "$SMOKE_REPO_ROOT/lib/bridge-a2a.sh"
_seen_header=0
while IFS=$'\t' read -r case_id line_esc expected; do
  [[ -z "$case_id" || "${case_id:0:1}" == "#" ]] && continue
  if [[ $_seen_header -eq 0 ]]; then _seen_header=1; continue; fi
  decoded="$(decode_case_line "$line_esc")"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$decoded"; } >"$BRIDGE_ROSTER_LOCAL_FILE"
  got="$(unset BRIDGE_ADMIN_AGENT_ID; shell_parse_case)"
  smoke_assert_eq "$expected" "$got" \
    "parity-table shell parser row '$case_id' matches bash ground truth"
done <"$CASES_TSV"
: >"$BRIDGE_ROSTER_FILE"

smoke_log "ALL 2081 launch-admin-id teeth PASS"
