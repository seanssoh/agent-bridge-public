#!/usr/bin/env bash
# scripts/smoke/2020-skills-assoc-declare.sh — #2020 (same class as #1407/#1627).
#
# Pins that `agent-roster.sh` declares BRIDGE_AGENT_SKILLS associative up front,
# BEFORE agent-roster.local.sh (which carries the
# `BRIDGE_AGENT_SKILLS["<agent>"]=...` assignments written by
# `agent roster materialize-fields --skills` / `agent create --skills`, #1427)
# is sourced. Without that declaration, a bare source of the two roster files
# evaluates the non-numeric subscript arithmetically → index 0 → a broken
# INDEXED array, so:
#   - bridge_var_is_assoc BRIDGE_AGENT_SKILLS is FALSE,
#   - bridge_agent_skills_csv reads back EMPTY (it guards on bridge_var_is_assoc),
#   - every per-agent assignment overwrites index [0] (multi-agent collision:
#     ${#BRIDGE_AGENT_SKILLS[@]} == 1, not 2),
#   - and bridge_sync_claude_runtime_skills materializes NO configured skill
#     into the agent's .claude/skills/ — silently, for ANY agent.
#
# The smoke drives the REAL agent-roster.sh + a REAL agent-roster.local.sh +
# the REAL accessors/sync (no stubs of bridge_agent_skills_csv or the maps), so
# it is non-vacuous. The MUTATION arm strips the `declare -Ag
# BRIDGE_AGENT_SKILLS` line from a copy of the roster and asserts the bug
# reproduces (FALSE / empty / count==1 / not-materialized) — proving the
# assertions have teeth.
#
# Per footgun #11 the in-driver bash is emitted line-by-line (no `<<EOF`
# heredoc-stdin to a subprocess).

set -euo pipefail

SMOKE_NAME="2020-skills-assoc-declare"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd bash
smoke_require_cmd python3

# Prefer a Bash 4+ interpreter (associative arrays). macOS /bin/bash is 3.2.
BRIDGE_BASH="${BASH:-bash}"
for cand in bash /opt/homebrew/bin/bash /usr/local/bin/bash; do
  if command -v "$cand" >/dev/null 2>&1; then
    ver="$("$cand" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
    if [[ "$ver" =~ ^[0-9]+$ ]] && (( ver >= 4 )); then
      BRIDGE_BASH="$cand"
      break
    fi
  fi
done
ver="$("$BRIDGE_BASH" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
[[ "$ver" =~ ^[0-9]+$ ]] && (( ver >= 4 )) \
  || smoke_fail "need a Bash 4+ interpreter for associative arrays (got '$ver' from $BRIDGE_BASH)"

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
FIXTURE="$SMOKE_TMP_ROOT/fixture"
mkdir -p "$FIXTURE"

# Real runtime skill sources the sync arm will link from. Export
# BRIDGE_RUNTIME_SKILLS_DIR (lib.sh pins BRIDGE_RUNTIME_ROOT but not this leaf)
# so the inherited driver's bridge_runtime_claude_skill_source_dir resolves it.
export BRIDGE_RUNTIME_SKILLS_DIR="$BRIDGE_HOME/runtime/skills"
RUNTIME_SKILLS="$BRIDGE_RUNTIME_SKILLS_DIR"
mkdir -p "$RUNTIME_SKILLS/skill-one" "$RUNTIME_SKILLS/skill-two"
printf '%s\n' '# skill-one' >"$RUNTIME_SKILLS/skill-one/SKILL.md"
printf '%s\n' '# skill-two' >"$RUNTIME_SKILLS/skill-two/SKILL.md"

# The two agents' workdirs live UNDER BRIDGE_AGENT_HOME_ROOT so the real
# bridge_sync_claude_runtime_skills within-root guard (lib/bridge-skills.sh) is
# satisfied.
AGENT_A="alpha"
AGENT_B="beta"
WORKDIR_A="$BRIDGE_AGENT_HOME_ROOT/$AGENT_A/workdir"
WORKDIR_B="$BRIDGE_AGENT_HOME_ROOT/$AGENT_B/workdir"
mkdir -p "$WORKDIR_A" "$WORKDIR_B"

# A local roster the way materialize-fields --skills / create --skills write it:
# bare `BRIDGE_AGENT_SKILLS["<agent>"]=...` assignments with NO local `declare`.
ROSTER_LOCAL="$FIXTURE/agent-roster.local.sh"
{
  printf '%s\n' "BRIDGE_AGENT_SKILLS[\"$AGENT_A\"]=\"skill-one,skill-two\""
  printf '%s\n' "BRIDGE_AGENT_SKILLS[\"$AGENT_B\"]=\"skill-one\""
} >"$ROSTER_LOCAL"

# The roster under test: the REAL repo agent-roster.sh (the file the fix edits).
ROSTER_FIXED="$FIXTURE/agent-roster.fixed.sh"
cp "$REPO_ROOT/agent-roster.sh" "$ROSTER_FIXED"

# Mutated copy with the SKILLS declaration removed — reproduces the pre-fix bug.
ROSTER_MUTATED="$FIXTURE/agent-roster.mutated.sh"
grep -v 'declare -Ag BRIDGE_AGENT_SKILLS=()' "$ROSTER_FIXED" >"$ROSTER_MUTATED"
# Guard: the mutation must actually have removed exactly the SKILLS declaration
# (so a future rename can't silently turn the mutation arm into a no-op that
# green-passes the same as the fixed arm).
if grep -q 'declare -Ag BRIDGE_AGENT_SKILLS=()' "$ROSTER_MUTATED"; then
  smoke_fail "mutation setup: SKILLS declaration still present in mutated roster — the strip did not take (check the declare text in agent-roster.sh)"
fi
if [[ "$(wc -l <"$ROSTER_FIXED")" == "$(wc -l <"$ROSTER_MUTATED")" ]]; then
  smoke_fail "mutation setup: fixed and mutated rosters have identical line counts — the SKILLS declaration line was not removed"
fi

# Driver: sources bridge-skills lib (real accessors + real sync), then sources
# the roster file (arg $2) and the local roster (bare assignments), EXACTLY the
# bare-source order the bridge uses (public roster, then local). It then prints
# the four observable facts and runs the real materialization sync. We do NOT
# call bridge_reset_roster_maps here — that lib function ALSO declares SKILLS
# (the belt); this arm exercises the file-level half (the suspenders, #2020) so
# a bare source of the roster files is correct on its own.
# $7 = "nounset" → run with `set -u` (the runtime contract). Under the FIXED
# roster this MUST complete cleanly (proving the fix also closes the
# `<agent>: unbound variable` abort mode the issue notes). The MUTATION arm runs
# with nounset OFF so the broken indexed array's SILENT index-0 collapse — the
# issue's documented primary symptom (declare -a ([0]=...), count==1, csv empty,
# no skill materialized) — is observable instead of aborting the driver early.
DRIVER="$FIXTURE/driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -o pipefail'
  printf '%s\n' 'REPO_ROOT="$1"'
  printf '%s\n' 'ROSTER="$2"'
  printf '%s\n' 'ROSTER_LOCAL="$3"'
  printf '%s\n' 'AGENT_A="$4"'
  printf '%s\n' 'AGENT_B="$5"'
  printf '%s\n' 'WORKDIR_A="$6"'
  printf '%s\n' 'NOUNSET="${7:-}"'
  # Minimal lib deps the skills module reaches outside its own file.
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_require_python() { command -v python3 >/dev/null 2>&1; }'
  # The materialization within-root guard keys on this; return 1 (within) so the
  # real link path runs against our temp workdir.
  printf '%s\n' 'bridge_path_is_within_root() { echo "1"; }'
  printf '%s\n' 'bridge_with_timeout() { shift 2; "$@"; }'
  # Source the REAL accessors (bridge_var_is_assoc + bridge_agent_skills_csv +
  # bridge_trim_whitespace live in bridge-agents.sh) and the REAL sync +
  # link helpers (bridge-skills.sh). No SKILLS-logic function is stubbed —
  # only infra helpers above (warn/python/within-root/with-timeout).
  printf '%s\n' '# shellcheck disable=SC1090'
  printf '%s\n' 'source "$REPO_ROOT/lib/bridge-agents.sh"'
  printf '%s\n' '# shellcheck disable=SC1090'
  printf '%s\n' 'source "$REPO_ROOT/lib/bridge-skills.sh"'
  printf '%s\n' '# shellcheck disable=SC1090'
  # Bare source, public roster then local — the exact order bridge_load_roster
  # uses for the standard (non-iso) path, minus the reset belt. Enable nounset
  # (the runtime contract) ONLY around the roster sourcing, so the FIXED arm
  # proves the declare also closes the `<agent>: unbound variable` abort mode,
  # while the lib sourcing above is unaffected.
  printf '%s\n' '[[ "$NOUNSET" == "nounset" ]] && set -u'
  printf '%s\n' 'source "$ROSTER"'
  printf '%s\n' 'source "$ROSTER_LOCAL"'
  printf '%s\n' 'set +u'
  # Observable 1: is the map associative?
  printf '%s\n' 'if bridge_var_is_assoc BRIDGE_AGENT_SKILLS; then echo "ASSOC=1"; else echo "ASSOC=0"; fi'
  # Observable 2: multi-agent count (broken indexed array collapses to 1).
  printf '%s\n' 'echo "COUNT=${#BRIDGE_AGENT_SKILLS[@]}"'
  # Observable 3: csv for agent A (real accessor; empty when non-assoc).
  printf '%s\n' 'echo "CSV_A=$(bridge_agent_skills_csv "$AGENT_A")"'
  printf '%s\n' 'echo "CSV_B=$(bridge_agent_skills_csv "$AGENT_B")"'
  # Observable 4: real materialization into the agent workdir .claude/skills/.
  printf '%s\n' 'bridge_sync_claude_runtime_skills "$AGENT_A" "$WORKDIR_A" >/dev/null 2>&1 || true'
  printf '%s\n' 'echo "DONE_REACHED=1"'
} >"$DRIVER"
chmod +x "$DRIVER"

run_driver() {
  local roster="$1" workdir_a="$2" nounset="${3:-}" out
  # Fresh workdir skills dir per run so the materialization assertion is clean.
  rm -rf "$workdir_a/.claude" 2>/dev/null || true
  mkdir -p "$workdir_a"
  out="$("$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$roster" "$ROSTER_LOCAL" \
    "$AGENT_A" "$AGENT_B" "$workdir_a" "$nounset" 2>&1)" \
    || smoke_fail "driver failed for roster=$roster (nounset=${nounset:-off}): $(printf '%s' "$out" | tr '\n' '|' | tail -c 800)"
  printf '%s' "$out"
}

field() { sed -n "s/^$1=//p" <<<"$2" | head -n1; }

# ---------- FIXED arm: the real agent-roster.sh, WITH nounset ----------
# nounset is the runtime contract; under the fix this must complete cleanly
# (no `<agent>: unbound variable` abort) AND produce a real assoc map.
OUT_FIXED="$(run_driver "$ROSTER_FIXED" "$WORKDIR_A" "nounset")"
[[ "$(field DONE_REACHED "$OUT_FIXED")" == "1" ]] \
  || smoke_fail "fixed: driver did not reach completion under set -u (the declare must close the unbound-variable abort mode). out: $(printf '%s' "$OUT_FIXED" | tr '\n' '|' | tail -c 600)"

smoke_assert_eq "1" "$(field ASSOC "$OUT_FIXED")" \
  "fixed: bridge_var_is_assoc BRIDGE_AGENT_SKILLS"
smoke_assert_eq "2" "$(field COUNT "$OUT_FIXED")" \
  "fixed: multi-agent map count (no index-0 collision)"
smoke_assert_eq "skill-one skill-two" "$(field CSV_A "$OUT_FIXED")" \
  "fixed: bridge_agent_skills_csv $AGENT_A"
smoke_assert_eq "skill-one" "$(field CSV_B "$OUT_FIXED")" \
  "fixed: bridge_agent_skills_csv $AGENT_B"

# The configured skills must actually materialize into the agent's workdir.
for skill in skill-one skill-two; do
  link="$WORKDIR_A/.claude/skills/$skill"
  [[ -e "$link" ]] \
    || smoke_fail "fixed: configured runtime skill '$skill' did NOT materialize into $WORKDIR_A/.claude/skills/ (the #2020 silent drop)"
  [[ -f "$link/SKILL.md" ]] \
    || smoke_fail "fixed: $link/SKILL.md not reachable through the materialized link"
done
# The UNCONFIGURED skill name must not appear.
[[ ! -e "$WORKDIR_A/.claude/skills/skill-unconfigured" ]] \
  || smoke_fail "fixed: an unconfigured skill materialized unexpectedly"

smoke_log "FIXED PASS: assoc=1, count=2, csv non-empty, skill-one + skill-two materialized under $AGENT_A/.claude/skills/"

# ---------- MUTATION arm: declaration removed → bug reproduces ----------
OUT_MUT="$(run_driver "$ROSTER_MUTATED" "$WORKDIR_A")"

smoke_assert_eq "0" "$(field ASSOC "$OUT_MUT")" \
  "mutation: WITHOUT the declare the map must NOT read as associative (proves the fixed-arm assoc assertion has teeth)"
smoke_assert_eq "1" "$(field COUNT "$OUT_MUT")" \
  "mutation: WITHOUT the declare the multi-agent assignments collapse to index 0 (count==1)"
smoke_assert_eq "" "$(field CSV_A "$OUT_MUT")" \
  "mutation: WITHOUT the declare bridge_agent_skills_csv reads back EMPTY (the silent-drop root cause)"

if [[ -e "$WORKDIR_A/.claude/skills/skill-one" ]]; then
  smoke_fail "mutation: skill-one materialized even WITHOUT the declare — the materialization assertion is vacuous"
fi

smoke_log "MUTATION PASS: WITHOUT the declare → assoc=0, count=1, csv empty, no skill materialized (bug reproduced)"

smoke_log "PASS: #2020 — agent-roster.sh declares BRIDGE_AGENT_SKILLS associative; configured runtime skills sync (multi-agent, no index-0 collision); mutation-checked."
