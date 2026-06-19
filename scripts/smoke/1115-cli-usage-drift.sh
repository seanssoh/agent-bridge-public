#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1115-cli-usage-drift.sh — Issues #1115 + #1116.
#
# Pins the contract that the agent-bridge CLI usage surfaces stay in lockstep
# with the dispatcher:
#
#   T1. The `_top_valid` typo-suggestion array in `agent-bridge` enumerates
#       every top-level branch in the `case "$1" in` block (and vice-versa),
#       so typos like `wav`, `a2x`, or `isolatio` reach `bridge_suggest_subcommand`.
#       Refs #1115: `_top_valid` was missing `a2a`, `wave`, `skills`, `isolation`.
#
#   T2. `scripts/cli-help/agent-bridge-usage.txt` documents every PUBLIC
#       top-level branch (each branch in `case "$1" in` must appear at least
#       once in the usage template — internal branches that route to bash
#       helpers without an operator-facing payload are pinned in
#       `_INTERNAL_TOPLEVEL` below).
#       Refs #1115: `a2a` and `plugins` were missing from the template.
#
#   T3. The PUBLIC `agent` subcommands (`bridge-agent.sh`'s case dispatch
#       minus the explicitly-pinned INTERNAL set) are all listed in the
#       template's `agent <…>` usage line.
#       Refs #1116: `doctor`, `rerender-settings`, `ack-crash`,
#       `forget-session` were missing from the agent usage line.
#
#   T4. The PUBLIC `cron` subcommands (`bridge-cron.sh`'s case dispatch
#       minus the explicitly-pinned INTERNAL set) are all listed in the
#       template's `cron <…>` usage line.
#       INTERNAL cron subcommand `finalize-run` (= bridge-daemon.sh
#       runtime callback) must ALSO be absent from the typo-suggestion
#       candidate list at the cron dispatcher's reject-path so operators
#       cannot reverse-engineer it. `migrate-payloads` is PUBLIC
#       (CHANGELOG-documented operator surface) and appears in both
#       template and reject-path candidates. Refs #1116.
#
# Plain-bash parse — no live BRIDGE_HOME required, no tmux. Footgun #11
# (heredoc_write deadlock class): every multi-line text uses `printf` /
# `awk` / `grep`, never `<<EOF` to a subprocess and never `<<<` here-strings
# (those need a writable TMPDIR — when bash cannot create the temp file the
# here-string degrades to empty silently, which made the v1 of this smoke
# pass-without-asserting in restricted sandboxes — codex catch 2026-05-23).

set -euo pipefail

SMOKE_NAME="1115-cli-usage-drift"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Set up a smoke-private tmp dir for any while-read-from-file backing.
# We do NOT call smoke_setup_bridge_home because this smoke parses source
# text only — but we do need a writable TMPDIR-equivalent for the loop
# inputs. smoke_make_temp_root respects $TMPDIR and falls back to /tmp.
smoke_make_temp_root "$SMOKE_NAME"
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
AGB_FILE="$REPO_ROOT/agent-bridge"
USAGE_FILE="$REPO_ROOT/scripts/cli-help/agent-bridge-usage.txt"
AGENT_DISPATCHER="$REPO_ROOT/bridge-agent.sh"
CRON_DISPATCHER="$REPO_ROOT/bridge-cron.sh"

smoke_assert_file_exists "$AGB_FILE" "agent-bridge dispatcher present"
smoke_assert_file_exists "$USAGE_FILE" "cli-help usage template present"
smoke_assert_file_exists "$AGENT_DISPATCHER" "bridge-agent.sh dispatcher present"
smoke_assert_file_exists "$CRON_DISPATCHER" "bridge-cron.sh dispatcher present"

# ---------------------------------------------------------------------------
# PUBLIC / INTERNAL pin lists.
#
# These are the only subcommands that may exist in the dispatcher without
# being enumerated in the operator-facing usage template. Anything else
# added to a `case "$cmd" in` block must either join the template OR be
# added here with a comment explaining why it is internal.
# ---------------------------------------------------------------------------

# Top-level branches that are dispatched + included in the typo-suggestion
# list but intentionally absent from the operator-facing usage template.
# Currently empty: the shorthand `create` (routes to bridge-task.sh) is
# documented at usage.txt:71 ("__CLI_NAME__ create --to …") because
# OPERATIONS.md and bin/agb explicitly steer operators to `agb create`.
# `iso-run`: hidden CLI facade for the bridge_iso_run shell helper, used
#   by Python callers (bridge_iso_paths.iso_run) that need to invoke the
#   unified controller->iso boundary helper from a non-shell process.
#   Documented inline at agent-bridge:921-947 + the lib header. Operators
#   never type it; keep it dispatchable + typo-discoverable but hide from
#   the operator-facing usage template.
# Future template-hidden additions land here with a comment explaining
# `resolver`: #1991 agentic blocked-prompt resolver (canary-gated, DEFAULT
#   OFF, patch-owned single-owner). Dispatchable (`agb resolver attempt|drain|
#   status`, see agent-bridge:1131 + bridge-resolver.sh) + typo-discoverable,
#   but hidden from the operator-facing usage template — a default-off canary
#   command shouldn't appear in every operator's `--help`. Same
#   dispatch-and-discover-but-hide-from-template pattern as `iso-run`.
# why operators shouldn't see them in `--help`.
TEMPLATE_ONLY_HIDDEN_TOPLEVEL=("iso-run" "resolver")

INTERNAL_AGENT_SUBCOMMANDS=()
# `finalize-run`: bridge-daemon.sh runtime callback that finalizes a
#   dispatched cron run record (see bridge-daemon.sh:5459). Operators never
#   invoke it directly — keep it dispatchable but hide from the
#   typo-suggestion candidate list so operators don't reverse-engineer it.
# `reactive-redispatch`: #1437 runtime callback invoked by the reactive
#   Claude-OAT-rotation path in bridge-cron-runner.py (maybe_reactive_rotate)
#   after a successful rotation, to re-enqueue the quota-failed cron job once.
#   Operators never invoke it directly — same internal contract as
#   finalize-run: dispatchable + honors `--help` (1117) but hidden from the
#   usage template and the typo-suggestion candidate list.
INTERNAL_CRON_SUBCOMMANDS=("finalize-run" "reactive-redispatch")

# ---------------------------------------------------------------------------
# Parsers.
#
# We deliberately parse the dispatcher source instead of invoking `agent-bridge
# --help`. The smoke must catch a drift PR even if a future refactor moves the
# usage emitter — the source is the single ground truth.
# ---------------------------------------------------------------------------

# Extract the top-level branches from agent-bridge's `case "$1" in` block.
# The block starts at the first `case "$1" in` that is preceded by the
# `if [[ $# -gt 0 ]]; then` guard and ends at the matching outer `esac`.
# Branches are 4-space-indented lowercase identifiers with optional digits
# (e.g. `a2a)`) optionally combined with `|` (e.g. `inbox|show|…)`.
parse_top_level_branches() {
  awk '
    /^if \[\[ \$# -gt 0 \]\]; then$/ { found = 1; next }
    found && /^  case "\$1" in$/ { in_case = 1; next }
    in_case && /^  esac$/ { exit }
    # Match only top-level (4-space) branches with the trailing `)`.
    in_case && /^    [a-z][a-z0-9_|-]*\)$/ {
      line = $0
      gsub(/[ \t)]/, "", line)
      n = split(line, parts, "|")
      for (i = 1; i <= n; i++) {
        if (parts[i] != "") print parts[i]
      }
    }
  ' "$AGB_FILE" | sort -u
}

# Extract the candidate list from the typo-suggestion `_top_valid` string.
parse_top_valid_array() {
  awk '
    /^[[:space:]]*_top_valid="/ {
      line = $0
      sub(/^[[:space:]]*_top_valid="/, "", line)
      sub(/".*$/, "", line)
      n = split(line, words, " ")
      for (i = 1; i <= n; i++) {
        if (words[i] != "") print words[i]
      }
      exit
    }
  ' "$AGB_FILE" | sort -u
}

# Extract the `agent <a|b|c>` subcommand alternation from the usage template.
# Returns one subcommand per line.
parse_template_agent_subcommands() {
  awk '
    /^[[:space:]]+__CLI_NAME__[[:space:]]+agent[[:space:]]+<[^>]+>/ {
      line = $0
      sub(/^.*<[[:space:]]*/, "", line)
      sub(/>.*$/, "", line)
      n = split(line, parts, "|")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        if (parts[i] != "") print parts[i]
      }
      exit
    }
  ' "$USAGE_FILE" | sort -u
}

parse_template_cron_subcommands() {
  awk '
    /^[[:space:]]+__CLI_NAME__[[:space:]]+cron[[:space:]]+<[^>]+>/ {
      line = $0
      sub(/^.*<[[:space:]]*/, "", line)
      sub(/>.*$/, "", line)
      n = split(line, parts, "|")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        if (parts[i] != "") print parts[i]
      }
      exit
    }
  ' "$USAGE_FILE" | sort -u
}

# Extract bridge-agent.sh's top-level `case "$subcommand" in` branches.
parse_dispatcher_agent_subcommands() {
  awk '
    /^case "\$subcommand" in$/ { in_case = 1; next }
    in_case && /^esac$/ { exit }
    # 2-space-indented identifiers in this file (run_* dispatch).
    in_case && /^  [a-z][a-z0-9_-]*\)$/ {
      line = $0
      gsub(/[ \t)]/, "", line)
      if (line != "") print line
    }
  ' "$AGENT_DISPATCHER" | sort -u
}

parse_dispatcher_cron_subcommands() {
  awk '
    /^case "\$subcommand" in$/ { in_case = 1; next }
    in_case && /^esac$/ { exit }
    in_case && /^  [a-z][a-z0-9_-]*\)$/ {
      line = $0
      gsub(/[ \t)]/, "", line)
      if (line != "") print line
    }
  ' "$CRON_DISPATCHER" | sort -u
}

# Extract the typo-suggestion candidate list from a dispatcher's reject path.
# Grep for the single quoted argument passed to bridge_suggest_subcommand.
# We accept both single-line and continuation forms.
parse_cron_reject_candidates() {
  awk '
    /bridge_suggest_subcommand "cron \$subcommand"/ { capture = 1; next }
    capture && /"[a-z]/ {
      line = $0
      # Strip everything before the first opening quote and after the
      # closing quote on the same line.
      sub(/^[^"]*"/, "", line)
      sub(/".*$/, "", line)
      n = split(line, words, " ")
      for (i = 1; i <= n; i++) {
        if (words[i] != "") print words[i]
      }
      exit
    }
  ' "$CRON_DISPATCHER" | sort -u
}

contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

assert_set_equal() {
  local context="$1"
  local expected_list="$2"
  local actual_list="$3"

  local missing
  missing="$(comm -23 <(printf '%s\n' "$expected_list") <(printf '%s\n' "$actual_list"))"
  local extra
  extra="$(comm -13 <(printf '%s\n' "$expected_list") <(printf '%s\n' "$actual_list"))"

  if [[ -n "$missing" || -n "$extra" ]]; then
    printf '%s\n' "[smoke:$SMOKE_NAME] context: $context" >&2
    local diag_file item
    diag_file="$SMOKE_TMP_ROOT/diag.$$.txt"
    if [[ -n "$missing" ]]; then
      printf '%s\n' "  missing from actual:" >&2
      printf '%s\n' "$missing" >"$diag_file"
      while IFS= read -r item; do
        [[ -n "$item" ]] && printf '    %s\n' "$item" >&2
      done <"$diag_file"
    fi
    if [[ -n "$extra" ]]; then
      printf '%s\n' "  unexpected in actual:" >&2
      printf '%s\n' "$extra" >"$diag_file"
      while IFS= read -r item; do
        [[ -n "$item" ]] && printf '    %s\n' "$item" >&2
      done <"$diag_file"
    fi
    rm -f "$diag_file"
    smoke_fail "$context: set drift"
  fi
}

# ---------------------------------------------------------------------------
# T1 — `_top_valid` array reflects the dispatcher's `case "$1" in` block.
# ---------------------------------------------------------------------------
smoke_log "T1: _top_valid array matches the top-level case-switch in agent-bridge"

DISPATCHED_TOP="$(parse_top_level_branches)"
TOP_VALID="$(parse_top_valid_array)"

if [[ -z "$DISPATCHED_TOP" ]]; then
  smoke_fail "T1: parser found no top-level branches — parser drift?"
fi
if [[ -z "$TOP_VALID" ]]; then
  smoke_fail "T1: parser found no entries in _top_valid — parser drift?"
fi

# `_top_valid` must include EVERY dispatched top-level branch — including
# the template-hidden shorthand `create` — so the typo-suggestion path
# resolves consistently regardless of whether a branch is documented.
assert_set_equal \
  "T1: _top_valid array vs dispatched top-level branches" \
  "$DISPATCHED_TOP" \
  "$TOP_VALID"

# ---------------------------------------------------------------------------
# T2 — Each PUBLIC top-level branch appears at least once in the usage
# template (anywhere — group line OR a fully-spelled-out subcommand line).
# ---------------------------------------------------------------------------
smoke_log "T2: every PUBLIC top-level branch appears in the usage template"

T2_LIST_FILE="$SMOKE_TMP_ROOT/t2-dispatched-top.txt"
printf '%s\n' "$DISPATCHED_TOP" >"$T2_LIST_FILE"
T2_SAW_ROW=0
while IFS= read -r cmd; do
  [[ -n "$cmd" ]] || continue
  T2_SAW_ROW=1
  if (( ${#TEMPLATE_ONLY_HIDDEN_TOPLEVEL[@]} > 0 )) \
      && contains "$cmd" "${TEMPLATE_ONLY_HIDDEN_TOPLEVEL[@]}"; then
    continue
  fi
  # Word-boundary grep: `__CLI_NAME__ <cmd>` with a trailing space or
  # angle bracket so we don't false-positive on `--cmd-something`.
  if ! grep -qE "__CLI_NAME__[[:space:]]+${cmd}([[:space:]<]|\$)" "$USAGE_FILE"; then
    smoke_fail "T2: top-level '$cmd' is dispatched but absent from $USAGE_FILE"
  fi
done <"$T2_LIST_FILE"
rm -f "$T2_LIST_FILE"
# Guard against the v1 silent-pass: if we iterated zero rows the parser is
# broken even though $DISPATCHED_TOP appeared non-empty above. Refs codex
# 2026-05-23 catch on the original `<<<` formulation.
if (( T2_SAW_ROW == 0 )); then
  smoke_fail "T2: loop iterated zero rows — parser/IO drift"
fi

# ---------------------------------------------------------------------------
# T3 — agent <…> usage line lists every PUBLIC agent subcommand.
# ---------------------------------------------------------------------------
smoke_log "T3: agent usage line lists every PUBLIC bridge-agent.sh subcommand"

DISPATCHED_AGENT="$(parse_dispatcher_agent_subcommands)"
TEMPLATE_AGENT="$(parse_template_agent_subcommands)"

if [[ -z "$DISPATCHED_AGENT" ]]; then
  smoke_fail "T3: parser found no agent subcommands — parser drift?"
fi
if [[ -z "$TEMPLATE_AGENT" ]]; then
  smoke_fail "T3: parser found no agent subcommands in template — parser drift?"
fi

EXPECTED_AGENT="$DISPATCHED_AGENT"
if (( ${#INTERNAL_AGENT_SUBCOMMANDS[@]} > 0 )); then
  internal_pattern="$(printf '%s\n' "${INTERNAL_AGENT_SUBCOMMANDS[@]}" | sort -u)"
  EXPECTED_AGENT="$(comm -23 <(printf '%s\n' "$DISPATCHED_AGENT") <(printf '%s\n' "$internal_pattern"))"
fi

# The agent dispatcher case has both a single-name (`create)`) and an
# explicit `--help` literal at the end which we already skip via the regex.
# Filter out the empty entry just in case.
EXPECTED_AGENT="$(printf '%s\n' "$EXPECTED_AGENT" | sed '/^$/d')"

assert_set_equal \
  "T3: agent template subcommands vs PUBLIC bridge-agent.sh dispatch" \
  "$EXPECTED_AGENT" \
  "$TEMPLATE_AGENT"

# ---------------------------------------------------------------------------
# T4 — cron <…> usage line lists every PUBLIC cron subcommand, AND the
# cron reject-path candidate list also omits the INTERNAL ones.
# ---------------------------------------------------------------------------
smoke_log "T4: cron usage line + reject-path candidates both hide internal subcommands"

DISPATCHED_CRON="$(parse_dispatcher_cron_subcommands)"
TEMPLATE_CRON="$(parse_template_cron_subcommands)"
CANDIDATE_CRON="$(parse_cron_reject_candidates)"

if [[ -z "$DISPATCHED_CRON" ]]; then
  smoke_fail "T4: parser found no cron subcommands — parser drift?"
fi
if [[ -z "$TEMPLATE_CRON" ]]; then
  smoke_fail "T4: parser found no cron subcommands in template — parser drift?"
fi
if [[ -z "$CANDIDATE_CRON" ]]; then
  smoke_fail "T4: parser found no entries in the cron reject candidate list"
fi

EXPECTED_CRON="$DISPATCHED_CRON"
if (( ${#INTERNAL_CRON_SUBCOMMANDS[@]} > 0 )); then
  internal_pattern="$(printf '%s\n' "${INTERNAL_CRON_SUBCOMMANDS[@]}" | sort -u)"
  EXPECTED_CRON="$(comm -23 <(printf '%s\n' "$DISPATCHED_CRON") <(printf '%s\n' "$internal_pattern"))"
fi
EXPECTED_CRON="$(printf '%s\n' "$EXPECTED_CRON" | sed '/^$/d')"

assert_set_equal \
  "T4a: cron template subcommands vs PUBLIC bridge-cron.sh dispatch" \
  "$EXPECTED_CRON" \
  "$TEMPLATE_CRON"

assert_set_equal \
  "T4b: cron reject-path candidate list vs PUBLIC bridge-cron.sh dispatch" \
  "$EXPECTED_CRON" \
  "$CANDIDATE_CRON"

# Belt-and-suspenders: explicitly assert each INTERNAL cron entry is
# absent from both surfaces — defends against a future PR that flips
# the INTERNAL_CRON_SUBCOMMANDS pin without removing the underlying
# template/candidate row.
for internal in "${INTERNAL_CRON_SUBCOMMANDS[@]}"; do
  if printf '%s\n' "$TEMPLATE_CRON" | grep -qx "$internal"; then
    smoke_fail "T4: INTERNAL cron subcommand '$internal' must NOT appear in usage template"
  fi
  if printf '%s\n' "$CANDIDATE_CRON" | grep -qx "$internal"; then
    smoke_fail "T4: INTERNAL cron subcommand '$internal' must NOT appear in reject candidate list"
  fi
done

smoke_log "passed"
