#!/usr/bin/env bash
# Hermetic mock of `agent-bridge` for the wiki-daily-ingest smoke.
# Returns valid JSON for `agent list --json` (default empty list so PR-D's
# strict Lane B parser sees zero active agents but parses cleanly).
# When AGB_MOCK_AGENT_LIST_JSON is set, that exact JSON string is returned
# instead — used by the v2 strict Lane B case to inject a populated agent
# roster pointing at a fixture workdir.
# Exits non-zero for `agent show librarian` (so the librarian-watchdog
# branch short-circuits), and no-ops for `task create` if ever reached.
# Any other subcommand exits non-zero so unexpected calls surface in test
# failures.

set -euo pipefail

case "${1:-}" in
  agent)
    case "${2:-}" in
      list)
        if [[ "${3:-}" == "--json" ]]; then
          if [[ -n "${AGB_MOCK_AGENT_LIST_JSON:-}" ]]; then
            printf '%s' "$AGB_MOCK_AGENT_LIST_JSON"
          else
            printf '[]'
          fi
          exit 0
        fi
        exit 1
        ;;
      show)
        # No librarian fixture in this smoke — let the watchdog probe fail.
        exit 1
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  task)
    if [[ "${2:-}" == "create" ]]; then
      # Issue #583 Track C r2: record `task create` argv so smoke scenarios
      # can prove the librarian-ingest task creation/non-creation contract
      # (scenario 11 asserts no [librarian-ingest] line for skipped isolated
      # agents; scenario 12 asserts one for the shared-agent passthrough;
      # scenarios 13 and 14 assert the same negative for legacy-path and
      # raw-walk skips respectively). When AGB_MOCK_TASK_LOG is unset the
      # mock stays a no-op so unrelated callers/tests are not perturbed.
      if [[ -n "${AGB_MOCK_TASK_LOG:-}" ]]; then
        printf '%s\n' "$*" >>"$AGB_MOCK_TASK_LOG"
      fi
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
