#!/usr/bin/env bash
# lib/bridge-provider-health.sh — shell accessors for the provider-health
# outage oracle (#2066 v0.17 fallback feature, P1a).
#
# 1 prober, N READERS. The daemon is the only writer (bridge-provider-health.py
# probe/report). Everything else only READS the state cheaply. These shell
# helpers are the cheap read path + the report entry the outage-class failure
# paths (P1b cron, P3 live) call. P1a ships them inert — nothing consumes DOWN
# yet — but wired and smoke-covered.
#
# The state file is daemon-owned JSON at $BRIDGE_STATE_DIR/daemon/provider-health,
# mode 0644 (non-secret observational), so an isolated agent UID can read it
# directly with no CLI round-trip. A missing/unreadable file reads as UP (the
# fail-safe default — never strand an agent on a fallback because the oracle
# file is absent).

# Resolve the repo script dir so we can find bridge-provider-health.py.
if [[ -z "${BRIDGE_PROVIDER_HEALTH_SCRIPT_DIR:-}" ]]; then
  BRIDGE_PROVIDER_HEALTH_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)"
fi

bridge_provider_health_state_file() {
  printf '%s/daemon/provider-health' "${BRIDGE_STATE_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
}

# Print the current provider-health state label (UP / DOWN-scoped:<agent> /
# DOWN-fleet). Reads the JSON state file directly (cheap, no python) and falls
# back to UP on any absence/parse failure. This is the N-readers path.
#
# Codex P1a (feature-gate bypass): when the master gate BRIDGE_FALLBACK_ENABLED
# is OFF (default), the reader reports UP regardless of any stale state file —
# a disabled install must NEVER let a leftover DOWN drive a fallback decision.
bridge_provider_health_state() {
  case "${BRIDGE_FALLBACK_ENABLED:-0}" in
    1|true|yes|on) ;;
    *) printf 'UP\n'; return 0 ;;
  esac
  local file
  file="$(bridge_provider_health_state_file)"
  if [[ ! -r "$file" ]]; then
    printf 'UP\n'
    return 0
  fi
  # Pure-python one-liner is overkill for a cheap read; grep the two fields out
  # of the pretty-printed JSON (sorted keys, one field per line). A parse miss
  # degrades to UP.
  local raw scoped
  raw="$(sed -n 's/.*"state": *"\([^"]*\)".*/\1/p' "$file" 2>/dev/null | head -1)"
  case "$raw" in
    DOWN-scoped)
      scoped="$(sed -n 's/.*"scoped_agent": *"\([^"]*\)".*/\1/p' "$file" 2>/dev/null | head -1)"
      printf 'DOWN-scoped:%s\n' "$scoped"
      ;;
    DOWN-fleet)
      printf 'DOWN-fleet\n'
      ;;
    UP|"")
      printf 'UP\n'
      ;;
    *)
      printf 'UP\n'
      ;;
  esac
}

# True (rc 0) when the provider is DOWN (scoped or fleet) for the given agent.
# An empty agent argument means "fleet-wide only". P1a callers do not exist yet
# (P1b/P3 wire the consumers) — this is the predicate they will use.
bridge_provider_health_is_down_for() {
  local agent="${1:-}"
  local state
  state="$(bridge_provider_health_state)"
  case "$state" in
    DOWN-fleet) return 0 ;;
    DOWN-scoped:*)
      [[ -n "$agent" && "$state" == "DOWN-scoped:$agent" ]] && return 0
      return 1
      ;;
    *) return 1 ;;
  esac
}

# Static-agent validation seam for the python oracle's FLEET quorum (codex P1a
# d2): the oracle is roster-blind, so the controller-side report wrapper passes
# a `bridge_agent_is_static` check command. The python side appends the agent
# name and runs it per reported agent; only validated static agents count toward
# fleet promotion. lib/provider-health-static-check.sh loads the roster and runs
# the canonical predicate, exiting 0 iff the agent is a registered static agent.
bridge_provider_health_static_check_cmd() {
  local bash_bin="${BRIDGE_BASH_BIN:-bash}"
  printf '%s %s/lib/provider-health-static-check.sh' \
    "$bash_bin" "$BRIDGE_PROVIDER_HEALTH_SCRIPT_DIR"
}

# Report an outage-class failure to the oracle (the detector ENTRY). Delegates
# to the python oracle which runs the confirm-probe + DNS sanity. Best-effort:
# a report failure must never break the calling failure path. Gated on the
# master switch — a disabled install records nothing (codex P1a feature-gate).
#   $1 agent  $2 source (cron|live)  $3 evidence (short; the oracle digests it)
bridge_provider_health_report_outage() {
  case "${BRIDGE_FALLBACK_ENABLED:-0}" in
    1|true|yes|on) ;;
    *) return 0 ;;
  esac
  local agent="${1:-unknown}"
  local source="${2:-unknown}"
  local evidence="${3:-}"
  BRIDGE_FALLBACK_STATIC_CHECK_CMD="${BRIDGE_FALLBACK_STATIC_CHECK_CMD:-$(bridge_provider_health_static_check_cmd)}" \
  python3 "$BRIDGE_PROVIDER_HEALTH_SCRIPT_DIR/bridge-provider-health.py" \
    report-outage --agent "$agent" --source "$source" --evidence "$evidence" \
    >/dev/null 2>&1 || true
}

# True (rc 0) when free-form text is outage-class (5xx/529/overloaded/reset).
# Shares the canonical classifier in bridge-usage-probe.py via the oracle CLI.
bridge_provider_health_text_is_outage() {
  local text="${1:-}"
  python3 "$BRIDGE_PROVIDER_HEALTH_SCRIPT_DIR/bridge-provider-health.py" \
    classify-text --text "$text" >/dev/null 2>&1
}
