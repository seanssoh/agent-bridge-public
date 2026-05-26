#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/I-agent-description-roster.sh — v0.15.0-beta1 Lane I.
#
# Pins the `BRIDGE_AGENT_DESC` operator-facing surface:
#
#   T1.  Roster-set description renders in `agent show <agent>` text output
#        on the canonical `description:` line.
#   T2.  `agent show <agent> --json` carries the same string verbatim as
#        the JSON `.description` field.
#   T3.  `agent list --json` carries the same string on the record for the
#        named agent.
#   T4.  `agent describe <agent>` prints the description + newline on
#        stdout with exit 0 when the desc is set.
#   T5.  A second agent with no `BRIDGE_AGENT_DESC` entry: `agent show`
#        still emits a stable `description:` line carrying the unset
#        hint (refs admin-agent-convention.md), and `agent describe`
#        exits non-zero with no stdout and a stderr hint pointing at
#        the roster file.
#   T6.  `declare -p BRIDGE_AGENT_DESC` after sourcing bridge-lib.sh +
#        bridge_load_roster confirms the variable is declared as an
#        associative array (`declare -A …`), not a scalar. Pins the
#        regression class catalogued in #1213 (assoc-array vs scalar
#        export collision) — adding a `BRIDGE_AGENT_DESCRIPTION` scalar
#        anywhere would fork the schema and trip an isolated agent's
#        roster reader.
#   T7.  No `BRIDGE_AGENT_DESC` and no `BRIDGE_AGENT_DESCRIPTION` scalar
#        survives into the agent's runtime environment under
#        `lib/bridge-agents.sh` env snapshotter (#1213 prevention).
#   T8.  `agent describe -h` and `agent describe --help` print
#        non-empty stdout with rc=0 (matches the #1117 universal --help
#        gate contract for the new verb).
#
# Footgun #11 (KNOWN_ISSUES.md §26): NO heredoc-stdin to subprocess
# anywhere — every captured stdout uses `out=$("$@" 2>&1)` and every
# Python invocation uses `python3 -c '…'` with the body as a single
# argv string, or a standalone helper file (no inline `<<'PY'`).
# Re-execs under Homebrew Bash 5+ on macOS hosts (system bash is 3.2).

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:I-agent-description-roster][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="I-agent-description-roster"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Pick a Bash 4+ interpreter for subprocess invocations.
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

PY_BIN="${PYTHON3:-python3}"

# Fixed strings for the two test agents — chosen to be distinctive enough
# that a substring match in show/list output can attribute the hit
# unambiguously.
AGENT_SET="i-desc-set"
AGENT_UNSET="i-desc-unset"
DESC_STRING="test role: queue-aware coordinator for Lane I smoke verification"

# ---------------------------------------------------------------------------
# Roster fixture
# ---------------------------------------------------------------------------
# Two static agents: one with BRIDGE_AGENT_DESC populated, one without.
# Engine/session/workdir filled in for both so the TSV emitter doesn't bail
# on missing required columns.
write_roster() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "$AGENT_SET"
BRIDGE_AGENT_DESC["$AGENT_SET"]="$DESC_STRING"
BRIDGE_AGENT_ENGINE["$AGENT_SET"]="claude"
BRIDGE_AGENT_SESSION["$AGENT_SET"]="$AGENT_SET"
BRIDGE_AGENT_WORKDIR["$AGENT_SET"]="$BRIDGE_AGENT_HOME_ROOT/$AGENT_SET"
BRIDGE_AGENT_SOURCE["$AGENT_SET"]="static"

bridge_add_agent_id_if_missing "$AGENT_UNSET"
BRIDGE_AGENT_ENGINE["$AGENT_UNSET"]="claude"
BRIDGE_AGENT_SESSION["$AGENT_UNSET"]="$AGENT_UNSET"
BRIDGE_AGENT_WORKDIR["$AGENT_UNSET"]="$BRIDGE_AGENT_HOME_ROOT/$AGENT_UNSET"
BRIDGE_AGENT_SOURCE["$AGENT_UNSET"]="static"
EOF
}

write_roster

# Scaffold the agent home roots so bridge-lib.sh's profile-home resolver
# doesn't synthesize a v2 layout marker pass that would mask roster
# behaviour we care about.
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$AGENT_SET" "$BRIDGE_AGENT_HOME_ROOT/$AGENT_UNSET"

agb_agent() {
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-agent.sh" "$@"
}

# Helper: run a subprocess that prints `declare -p BRIDGE_AGENT_DESC` AFTER
# sourcing bridge-lib.sh + bridge_load_roster. Stand-alone helper file
# would be overkill; the body is a small fixed Bash command string with
# no heredoc, no `<<<`, no `$()` chained around heredocs.
roster_declare_p() {
  "$BRIDGE_BASH" -c \
    "set +u; cd \"$REPO_ROOT\" && source ./bridge-lib.sh >/dev/null 2>&1; bridge_load_roster >/dev/null 2>&1; declare -p BRIDGE_AGENT_DESC 2>/dev/null"
}

# Helper: capture the BRIDGE_AGENT_DESC variable from `env` after loading
# the roster. We force the loader to run via a subshell, then `env | grep`
# for any scalar export. The roster's `declare -A BRIDGE_AGENT_DESC` lives
# in shell scope; `env` only surfaces explicitly exported scalars.
env_has_scalar() {
  local var_name="$1"
  "$BRIDGE_BASH" -c \
    "set +u; cd \"$REPO_ROOT\" && source ./bridge-lib.sh >/dev/null 2>&1; bridge_load_roster >/dev/null 2>&1; env | grep -E \"^${var_name}=\" || true"
}

# ---------------------------------------------------------------------------
# T1: roster-set description renders in `agent show <agent>` text output
# ---------------------------------------------------------------------------
smoke_log "T1: agent show <set-agent> carries description in text mode"
SHOW_TEXT_OUT="$(agb_agent show "$AGENT_SET" 2>&1)" || smoke_fail "T1: agent show rc!=0"
smoke_assert_contains "$SHOW_TEXT_OUT" "description: $DESC_STRING" \
  "T1: text output carries 'description: <DESC_STRING>'"
smoke_assert_contains "$SHOW_TEXT_OUT" "agent: $AGENT_SET" \
  "T1: text output identifies the agent we asked about"

# ---------------------------------------------------------------------------
# T2: JSON `agent show` carries description
# ---------------------------------------------------------------------------
smoke_log "T2: agent show <set-agent> --json carries .description"
SHOW_JSON_OUT="$(agb_agent show "$AGENT_SET" --json 2>&1)" || smoke_fail "T2: show --json rc!=0"

# Drive every JSON inspection through a small file-based Python helper so
# we avoid the footgun #11 heredoc-stdin deadlock class. The helper takes
# (agent_id, json_file) on argv and prints the description string. Same
# precedent as lib/upgrade-helpers/ (file-as-argv, no stdin heredoc).
HELPER_DIR="$SMOKE_TMP_ROOT/helpers"
mkdir -p "$HELPER_DIR"
cat >"$HELPER_DIR/extract-desc.py" <<'PYHELPER'
"""Extract description from `agent show --json` or `agent list --json`.

Usage:
  python3 extract-desc.py <agent_id> <json_file>

Prints the description string for <agent_id> on stdout, exit 0. Empty
string on stdout + exit 1 if the agent is not present or has no
description key. NOT stdin-driven, NOT heredoc-bodied — argv-only,
file-based input, satisfies the Lane I no-heredoc-stdin constraint.
"""
import json
import sys


def find_record(doc, agent_id):
    """Walk the show/list shape and return the dict that carries description."""
    if isinstance(doc, dict):
        # show --json top-level shape: {"agent": "<id>", "description": "...", ...}
        if doc.get("agent") == agent_id and "description" in doc:
            return doc
        # show --json may wrap the record under `.agent` as an object.
        nested = doc.get("agent")
        if isinstance(nested, dict) and nested.get("agent") == agent_id:
            return nested
        # list --json shape can be {"agents": [...]} too.
        records = doc.get("agents")
        if isinstance(records, list):
            for rec in records:
                if isinstance(rec, dict) and rec.get("agent") == agent_id:
                    return rec
    if isinstance(doc, list):
        for rec in doc:
            if isinstance(rec, dict) and rec.get("agent") == agent_id:
                return rec
    return None


def main():
    if len(sys.argv) != 3:
        print("usage: extract-desc.py <agent_id> <json_file>", file=sys.stderr)
        sys.exit(2)
    agent_id = sys.argv[1]
    json_path = sys.argv[2]
    with open(json_path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
    rec = find_record(doc, agent_id)
    if rec is None:
        sys.exit(1)
    # `description` may be absent on schema drift; treat absence as exit 1
    # so the smoke fails loudly on producer-side bugs.
    if "description" not in rec:
        sys.exit(1)
    print(rec["description"])


if __name__ == "__main__":
    main()
PYHELPER

printf '%s' "$SHOW_JSON_OUT" >"$HELPER_DIR/show.json"
SHOW_DESC="$("$PY_BIN" "$HELPER_DIR/extract-desc.py" "$AGENT_SET" "$HELPER_DIR/show.json" 2>&1)" \
  || smoke_fail "T2: extract-desc.py could not find description for $AGENT_SET in show --json"
smoke_assert_eq "$DESC_STRING" "$SHOW_DESC" "T2: show --json .description matches roster string"

# ---------------------------------------------------------------------------
# T3: `agent list --json` carries the description on the named record
# ---------------------------------------------------------------------------
smoke_log "T3: agent list --json carries .description for set-agent"
LIST_JSON_OUT="$(agb_agent list --json 2>&1)" || smoke_fail "T3: list --json rc!=0"
printf '%s' "$LIST_JSON_OUT" >"$HELPER_DIR/list.json"
LIST_DESC="$("$PY_BIN" "$HELPER_DIR/extract-desc.py" "$AGENT_SET" "$HELPER_DIR/list.json" 2>&1)" \
  || smoke_fail "T3: extract-desc.py could not find description for $AGENT_SET in list --json"
smoke_assert_eq "$DESC_STRING" "$LIST_DESC" "T3: list --json record carries description verbatim"

# ---------------------------------------------------------------------------
# T4: `agent describe <agent>` prints the description on stdout, exit 0
# ---------------------------------------------------------------------------
smoke_log "T4: agent describe <set-agent> prints description on stdout"
DESCRIBE_OUT=""
DESCRIBE_OUT="$(agb_agent describe "$AGENT_SET" 2>/dev/null)"
DESCRIBE_RC=$?
smoke_assert_eq "0" "$DESCRIBE_RC" "T4: agent describe rc==0 when desc is set"
# stdout is the description + newline. Compare without the trailing newline.
smoke_assert_eq "$DESC_STRING" "$DESCRIBE_OUT" "T4: stdout equals the roster description string"

# ---------------------------------------------------------------------------
# T5: unset agent — show emits hint, describe fails with stderr hint
# ---------------------------------------------------------------------------
smoke_log "T5a: agent show <unset-agent> emits the unset-description hint"
SHOW_UNSET_OUT="$(agb_agent show "$AGENT_UNSET" 2>&1)" || smoke_fail "T5: show rc!=0 on unset"
smoke_assert_contains "$SHOW_UNSET_OUT" "no description set" \
  "T5a: text output carries the actionable unset hint"
smoke_assert_contains "$SHOW_UNSET_OUT" "BRIDGE_AGENT_DESC[\"$AGENT_UNSET\"]" \
  "T5a: text output names the roster key the operator should edit"

smoke_log "T5b: agent describe <unset-agent> exits non-zero with no stdout"
DESCRIBE_UNSET_STDOUT=""
DESCRIBE_UNSET_STDERR=""
DESCRIBE_UNSET_STDOUT="$(agb_agent describe "$AGENT_UNSET" 2>"$HELPER_DIR/describe-unset.err")"
DESCRIBE_UNSET_RC=$?
DESCRIBE_UNSET_STDERR="$(cat "$HELPER_DIR/describe-unset.err")"
[[ $DESCRIBE_UNSET_RC -ne 0 ]] \
  || smoke_fail "T5b: agent describe rc==0 on unset (expected non-zero), stdout='$DESCRIBE_UNSET_STDOUT' stderr='$DESCRIBE_UNSET_STDERR'"
smoke_assert_eq "" "$DESCRIBE_UNSET_STDOUT" \
  "T5b: agent describe stdout is empty on unset (caller piping value sees ''/empty)"
smoke_assert_contains "$DESCRIBE_UNSET_STDERR" "BRIDGE_AGENT_DESC[\"$AGENT_UNSET\"]" \
  "T5b: stderr hint names the roster key"
smoke_assert_contains "$DESCRIBE_UNSET_STDERR" "agent-roster.local.sh" \
  "T5b: stderr hint names the roster file"

# ---------------------------------------------------------------------------
# T6: declare -p BRIDGE_AGENT_DESC confirms assoc array form
# ---------------------------------------------------------------------------
smoke_log "T6: declare -p BRIDGE_AGENT_DESC confirms declare -A"
DECLARE_OUT="$(roster_declare_p)" || true
# Must start with `declare -A` — the assoc-array marker. A scalar export
# (which #1213 forbids re-introducing) would show `declare --` instead.
if [[ "$DECLARE_OUT" != "declare -A BRIDGE_AGENT_DESC="* ]]; then
  smoke_fail "T6: declare -p does not report BRIDGE_AGENT_DESC as 'declare -A' (got: $DECLARE_OUT)"
fi
# And it must carry the AGENT_SET → DESC_STRING entry.
smoke_assert_contains "$DECLARE_OUT" "[$AGENT_SET]=\"$DESC_STRING\"" \
  "T6: declare -p carries the AGENT_SET → DESC_STRING entry"

# ---------------------------------------------------------------------------
# T7: env has no scalar BRIDGE_AGENT_DESC / BRIDGE_AGENT_DESCRIPTION export
# ---------------------------------------------------------------------------
smoke_log "T7: no scalar BRIDGE_AGENT_DESC or BRIDGE_AGENT_DESCRIPTION in env"
ENV_DESC="$(env_has_scalar "BRIDGE_AGENT_DESC")"
ENV_DESCRIPTION="$(env_has_scalar "BRIDGE_AGENT_DESCRIPTION")"
smoke_assert_eq "" "$ENV_DESC" "T7a: env carries no scalar BRIDGE_AGENT_DESC export"
smoke_assert_eq "" "$ENV_DESCRIPTION" "T7b: env carries no scalar BRIDGE_AGENT_DESCRIPTION export (#1213 fork prevention)"

# ---------------------------------------------------------------------------
# T8: agent describe -h / --help — universal help contract
# ---------------------------------------------------------------------------
smoke_log "T8: agent describe -h / --help print non-empty stdout with rc=0"
for flag in -h --help; do
  HELP_OUT="$(agb_agent describe "$flag" 2>&1)"
  HELP_RC=$?
  if [[ $HELP_RC -ne 0 ]]; then
    smoke_fail "T8: agent describe $flag rc=$HELP_RC (expected 0)"
  fi
  if [[ ${#HELP_OUT} -eq 0 ]]; then
    smoke_fail "T8: agent describe $flag stdout was empty (expected usage)"
  fi
  # The #1117 ERROR_MARKERS list forbids "지원하지 않는" / "등록된 에이전트:" /
  # similar markers on a --help path. Spot-check the two most relevant.
  for marker in "지원하지 않는" "등록된 에이전트:"; do
    if [[ "$HELP_OUT" == *"$marker"* ]]; then
      smoke_fail "T8: agent describe $flag output contained 1117 ERROR_MARKER '$marker'"
    fi
  done
done

smoke_log "passed"
exit 0
