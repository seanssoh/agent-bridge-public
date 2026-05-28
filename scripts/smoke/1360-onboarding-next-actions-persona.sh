#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1360-onboarding-next-actions-persona.sh — issue #1360.
#
# Pins the persona-aware `agent show` next_actions + `agent create`
# next_steps surface added by PR #1364 (Track I). Eight assertions:
#
#   T1.  `bridge_agent_next_actions_tsv` maps `credentials_status=missing`
#        on a discord channel to the `agb setup discord <agent>` row
#        (placeholder_safe=yes).
#   T2.  Same mapping for `credentials_status=unreadable` — i.e. the
#        unreadable state does NOT fall through to the generic
#        `agent start --dry-run` row. (codex r1 PR #1364 BLOCKING 2.)
#   T3.  Same mapping for `credentials_status=missing` on a teams
#        channel — covers the multi-provider case head and proves the
#        per-provider setup verb routes correctly.
#   T4.  Per-channel hint for an unknown / custom provider falls back to
#        the generic `agent show` hint instead of inventing a setup verb.
#   T5.  `bridge_create_next_steps_lines` for a terminal-only static
#        agent (no channels, no isolation) emits dry-run + start +
#        attach + memory init + status — i.e. the persona produces the
#        full onboarding checklist, not just dry-run + status. (codex r1
#        PR #1364 BLOCKING 3.)
#   T6.  Same helper for a discord-channel agent emits the discord
#        setup verb + agent show re-check, and does NOT emit the
#        terminal-only attach/memory rows (channel-wired persona).
#   T7.  Same helper for a plugin-enabled linux-user isolated agent
#        emits the plugins seed + skills list rows + the iso v2
#        CLI-mediated-access note line.
#   T8.  The `agent show --json` envelope carries a top-level
#        `.next_actions` list whose first entry's `placeholder_safe`
#        round-trips as a JSON boolean (not the string "yes"/"no"),
#        proving the standalone helper substitution lands the same
#        shape as the prior inline form.
#
# Footgun #11 (KNOWN_ISSUES.md §26): NO heredoc-stdin to subprocess
# anywhere in this smoke — every Python invocation uses argv-only,
# every shell stub uses `cat >file <<EOF` (file write, NOT stdin to
# subprocess), and `bridge_agent_channel_diagnostics_tsv` is overridden
# in shell scope so the smoke does not need to fabricate credential
# files. Re-execs under Homebrew Bash 5+ on macOS hosts (system bash
# is 3.2).

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1360-onboarding-next-actions-persona][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="1360-onboarding-next-actions-persona"
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

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

PY_BIN="${PYTHON3:-python3}"

# ---------------------------------------------------------------------------
# Roster fixture: three agents that exercise the three persona arms.
#  - terminal-only-1   no channels, shared mode (terminal-only persona)
#  - discord-creds-1   plugin:discord (channel-wired persona)
#  - teams-creds-1     plugin:teams   (channel-wired persona — multi-provider)
# ---------------------------------------------------------------------------
write_roster() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "terminal-only-1"
BRIDGE_AGENT_ENGINE["terminal-only-1"]="claude"
BRIDGE_AGENT_SESSION["terminal-only-1"]="terminal-only-1"
BRIDGE_AGENT_WORKDIR["terminal-only-1"]="$BRIDGE_AGENT_HOME_ROOT/terminal-only-1"
BRIDGE_AGENT_SOURCE["terminal-only-1"]="static"

bridge_add_agent_id_if_missing "discord-creds-1"
BRIDGE_AGENT_ENGINE["discord-creds-1"]="claude"
BRIDGE_AGENT_SESSION["discord-creds-1"]="discord-creds-1"
BRIDGE_AGENT_WORKDIR["discord-creds-1"]="$BRIDGE_AGENT_HOME_ROOT/discord-creds-1"
BRIDGE_AGENT_SOURCE["discord-creds-1"]="static"
BRIDGE_AGENT_CHANNELS["discord-creds-1"]="plugin:discord"

bridge_add_agent_id_if_missing "teams-creds-1"
BRIDGE_AGENT_ENGINE["teams-creds-1"]="claude"
BRIDGE_AGENT_SESSION["teams-creds-1"]="teams-creds-1"
BRIDGE_AGENT_WORKDIR["teams-creds-1"]="$BRIDGE_AGENT_HOME_ROOT/teams-creds-1"
BRIDGE_AGENT_SOURCE["teams-creds-1"]="static"
BRIDGE_AGENT_CHANNELS["teams-creds-1"]="plugin:teams"
EOF
}

write_roster
mkdir -p \
  "$BRIDGE_AGENT_HOME_ROOT/terminal-only-1" \
  "$BRIDGE_AGENT_HOME_ROOT/discord-creds-1" \
  "$BRIDGE_AGENT_HOME_ROOT/teams-creds-1"

# ---------------------------------------------------------------------------
# Helper: run a stand-alone Bash 4+ subprocess that sources bridge-lib.sh,
# overrides `bridge_agent_channel_diagnostics_tsv` with a fixture-driven
# stub, and prints the `bridge_agent_next_actions_tsv` result for an
# agent. The fixture rows are passed via env (BRIDGE_TEST_DIAG_ROWS, one
# row per line, already in TSV form minus the header — the stub prepends
# the header).
#
# No heredoc-stdin to subprocess: we pass a single -c body string, no
# `<<<` here-strings, no chained `$()`-around-heredoc. Diagnostics rows
# travel via env variable, not stdin.
# ---------------------------------------------------------------------------
next_actions_tsv() {
  local agent="$1"
  local diag_rows="$2"
  BRIDGE_TEST_DIAG_ROWS="$diag_rows" "$BRIDGE_BASH" -c '
    set +u
    cd "$0" || exit 99
    source ./bridge-lib.sh >/dev/null 2>&1
    bridge_load_roster >/dev/null 2>&1
    # Stub the diagnostics producer. Header first, then any rows the
    # test passed via the env. An empty BRIDGE_TEST_DIAG_ROWS means
    # "no channel rows" (terminal-only persona).
    bridge_agent_channel_diagnostics_tsv() {
      printf "channel\tprovider\tplugin_spec\tplugin_status\tplugin_installed\tplugin_enabled\tlaunch_allowlisted\taccess_status\tcredentials_status\truntime_ready\tstate_dir\n"
      if [[ -n "${BRIDGE_TEST_DIAG_ROWS:-}" ]]; then
        printf "%s\n" "$BRIDGE_TEST_DIAG_ROWS"
      fi
    }
    # Force the channels_csv read to match what the diag rows imply,
    # so the per-channel walker actually runs even though the roster
    # fixture has no real plugin install.
    bridge_agent_channels_csv() {
      printf "%s" "${BRIDGE_TEST_CHANNELS_CSV:-}"
    }
    # Force isolation mode for the test agent (defaults to shared).
    bridge_agent_isolation_mode() {
      printf "%s" "${BRIDGE_TEST_ISOLATION_MODE:-shared}"
    }
    # No broken-launch marker and no looped state by default.
    bridge_agent_broken_launch_file() { printf "%s" "${BRIDGE_TEST_BROKEN_LAUNCH_FILE:-/nonexistent-broken-launch}"; }
    bridge_agent_loop() { printf "%s" "${BRIDGE_TEST_LOOP_MODE:-0}"; }
    bridge_agent_next_actions_tsv "$1"
  ' "$REPO_ROOT" "$agent"
}

create_next_steps_lines() {
  local agent="$1"
  local engine="$2"
  local channels="$3"
  local isolation_mode="$4"
  "$BRIDGE_BASH" -c '
    set +u
    cd "$0" || exit 99
    source ./bridge-lib.sh >/dev/null 2>&1
    bridge_create_next_steps_lines "$1" "$2" "$3" "$4"
  ' "$REPO_ROOT" "$agent" "$engine" "$channels" "$isolation_mode"
}

# ---------------------------------------------------------------------------
# T1: discord channel + credentials_status=missing → setup discord row
# ---------------------------------------------------------------------------
smoke_log "T1: discord channel missing creds → 'agb setup discord' row"
DIAG_DISCORD_MISSING=$'plugin:discord\tdiscord\tdiscord\tenabled\tyes\tyes\tyes\tn/a\tmissing\tno\tmissing'
export BRIDGE_TEST_CHANNELS_CSV="plugin:discord"
OUT="$(next_actions_tsv "discord-creds-1" "$DIAG_DISCORD_MISSING")"
smoke_assert_contains "$OUT" "agent-bridge setup discord discord-creds-1" \
  "T1: TSV carries 'agb setup discord' row for credentials_status=missing"
smoke_assert_contains "$OUT" "credentials are missing" \
  "T1: TSV carries the 'missing' reason string"

# ---------------------------------------------------------------------------
# T2: discord channel + credentials_status=unreadable → SAME setup row
# (codex r1 BLOCKING 2 — `unreadable` must NOT fall through to the
# generic dry-run row).
# ---------------------------------------------------------------------------
smoke_log "T2: discord channel unreadable creds → 'agb setup discord' row (not dry-run fall-through)"
DIAG_DISCORD_UNREADABLE=$'plugin:discord\tdiscord\tdiscord\tenabled\tyes\tyes\tyes\tn/a\tunreadable\tno\tpresent'
export BRIDGE_TEST_CHANNELS_CSV="plugin:discord"
OUT="$(next_actions_tsv "discord-creds-1" "$DIAG_DISCORD_UNREADABLE")"
smoke_assert_contains "$OUT" "agent-bridge setup discord discord-creds-1" \
  "T2: TSV routes 'unreadable' to the setup wizard row"
smoke_assert_contains "$OUT" "credentials are unreadable" \
  "T2: TSV carries the 'unreadable' reason string distinct from 'missing'"
smoke_assert_not_contains "$OUT" "agent-bridge agent start discord-creds-1 --dry-run" \
  "T2: 'unreadable' does NOT fall through to the generic 'agent start --dry-run' row (BLOCKING 2)"

# ---------------------------------------------------------------------------
# T3: teams channel + credentials_status=missing → setup teams row
# ---------------------------------------------------------------------------
smoke_log "T3: teams channel missing creds → 'agb setup teams' row"
DIAG_TEAMS_MISSING=$'plugin:teams\tteams\tteams\tenabled\tyes\tyes\tyes\tn/a\tmissing\tno\tmissing'
export BRIDGE_TEST_CHANNELS_CSV="plugin:teams"
OUT="$(next_actions_tsv "teams-creds-1" "$DIAG_TEAMS_MISSING")"
smoke_assert_contains "$OUT" "agent-bridge setup teams teams-creds-1" \
  "T3: TSV carries 'agb setup teams' row for credentials_status=missing"

# ---------------------------------------------------------------------------
# T4: unknown provider + credentials_status=missing → generic show hint
# (no fabricated setup verb).
# ---------------------------------------------------------------------------
smoke_log "T4: unknown provider missing creds → generic 'agent show' hint"
DIAG_UNKNOWN_MISSING=$'plugin:somecustom\tcustom\tsomecustom\tenabled\tyes\tyes\tyes\tn/a\tmissing\tno\tmissing'
export BRIDGE_TEST_CHANNELS_CSV="plugin:somecustom"
OUT="$(next_actions_tsv "terminal-only-1" "$DIAG_UNKNOWN_MISSING")"
smoke_assert_not_contains "$OUT" "agent-bridge setup somecustom" \
  "T4: TSV does NOT invent a 'setup somecustom' verb for an unknown provider"
smoke_assert_contains "$OUT" "agent-bridge agent show terminal-only-1" \
  "T4: TSV falls back to the generic 'agent show' hint for unknown providers"
unset BRIDGE_TEST_CHANNELS_CSV

# ---------------------------------------------------------------------------
# T5: terminal-only static agent persona → start + attach + memory init
# (codex r1 BLOCKING 3 — must NOT be just dry-run + status).
# ---------------------------------------------------------------------------
smoke_log "T5: terminal-only persona emits the full onboarding checklist"
OUT="$(create_next_steps_lines "terminal-only-1" "claude" "" "shared")"
smoke_assert_contains "$OUT" "bash bridge-start.sh terminal-only-1 --dry-run" \
  "T5: terminal-only persona keeps the universal dry-run row"
smoke_assert_contains "$OUT" "agent-bridge agent start terminal-only-1" \
  "T5: terminal-only persona emits the real start verb (BLOCKING 3)"
smoke_assert_contains "$OUT" "agent-bridge attach terminal-only-1" \
  "T5: terminal-only persona emits the attach hint (BLOCKING 3)"
smoke_assert_contains "$OUT" "agent-bridge memory init --agent terminal-only-1" \
  "T5: terminal-only persona emits the memory/onboarding init hint (BLOCKING 3)"
smoke_assert_contains "$OUT" "agent-bridge status --all-agents" \
  "T5: terminal-only persona keeps the universal status row"

# ---------------------------------------------------------------------------
# T6: channel-wired (discord) persona does NOT emit the terminal-only rows
# (the attach + memory init lines belong only to the terminal-only persona).
# ---------------------------------------------------------------------------
smoke_log "T6: discord-channel persona does not emit terminal-only attach/memory rows"
OUT="$(create_next_steps_lines "discord-creds-1" "claude" "plugin:discord" "shared")"
smoke_assert_contains "$OUT" "agent-bridge setup discord discord-creds-1" \
  "T6: discord persona emits the discord setup wizard row"
smoke_assert_contains "$OUT" "agent-bridge agent show discord-creds-1" \
  "T6: discord persona emits the agent show re-check row"
smoke_assert_not_contains "$OUT" "agent-bridge attach discord-creds-1" \
  "T6: discord persona does NOT emit the terminal-only attach row"
smoke_assert_not_contains "$OUT" "agent-bridge memory init --agent discord-creds-1" \
  "T6: discord persona does NOT emit the terminal-only memory init row"

# ---------------------------------------------------------------------------
# T7: plugin-enabled linux-user isolated agent persona emits the plugin
# seed + skills list + iso v2 note line.
# ---------------------------------------------------------------------------
smoke_log "T7: plugin-enabled linux-user isolated persona"
OUT="$(create_next_steps_lines "discord-creds-1" "claude" "plugin:discord" "linux-user")"
smoke_assert_contains "$OUT" "agent-bridge plugins seed --agent discord-creds-1" \
  "T7: iso+plugin persona emits the plugin seed row"
smoke_assert_contains "$OUT" "agent-bridge skills list --agent discord-creds-1" \
  "T7: iso+plugin persona emits the skills list row"
smoke_assert_contains "$OUT" "note: iso v2" \
  "T7: iso persona emits the iso v2 CLI-mediated-access note line"

# ---------------------------------------------------------------------------
# T8: next_actions JSON envelope shape — placeholder_safe must be a bool.
# Drives the standalone helper directly with a known TSV file, then
# parses the result via a file-based Python helper (argv-only, no
# heredoc-stdin) to assert the type.
# ---------------------------------------------------------------------------
smoke_log "T8: next_actions JSON envelope encodes placeholder_safe as a bool"
HELPER_DIR="$SMOKE_TMP_ROOT/helpers"
mkdir -p "$HELPER_DIR"
TSV_FILE="$HELPER_DIR/next-actions.tsv"
printf 'run\treason\tplaceholder_safe\nagent-bridge setup discord acme\tdiscord channel configured but credentials are missing; run the setup wizard\tyes\n' >"$TSV_FILE"

JSON_OUT="$("$PY_BIN" "$REPO_ROOT/lib/agent-cli-helpers/next-actions-tsv-to-json.py" "$TSV_FILE")" \
  || smoke_fail "T8: helper exited non-zero on a well-formed TSV"
printf '%s' "$JSON_OUT" >"$HELPER_DIR/next-actions.json"

cat >"$HELPER_DIR/assert-bool.py" <<'PYHELPER'
"""Assert that .next_actions[0].placeholder_safe is a JSON bool.

Usage: assert-bool.py <json_file>
Exit 0 on bool True/False; non-zero (with stderr) otherwise.
"""
import json
import sys


def main():
    if len(sys.argv) != 2:
        print("usage: assert-bool.py <json_file>", file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        payload = json.load(fh)
    if not isinstance(payload, list) or not payload:
        print(f"expected non-empty list, got: {payload!r}", file=sys.stderr)
        sys.exit(1)
    first = payload[0]
    val = first.get("placeholder_safe")
    if not isinstance(val, bool):
        print(
            f"placeholder_safe is not a bool — got {type(val).__name__}: {val!r}",
            file=sys.stderr,
        )
        sys.exit(1)
    # Also confirm the run + reason fields round-tripped.
    if not isinstance(first.get("run"), str) or not first["run"]:
        print("run is missing or not a non-empty string", file=sys.stderr)
        sys.exit(1)
    if not isinstance(first.get("reason"), str) or not first["reason"]:
        print("reason is missing or not a non-empty string", file=sys.stderr)
        sys.exit(1)
    print("ok")


if __name__ == "__main__":
    main()
PYHELPER

if ! "$PY_BIN" "$HELPER_DIR/assert-bool.py" "$HELPER_DIR/next-actions.json" >/dev/null 2>"$HELPER_DIR/assert-bool.err"; then
  smoke_fail "T8: next_actions JSON shape assertion failed: $(cat "$HELPER_DIR/assert-bool.err")"
fi

smoke_log "passed"
exit 0
