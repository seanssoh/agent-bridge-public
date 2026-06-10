#!/usr/bin/env bash
# codex-orphan-cleanup.sh — upgrade-time one-shot reaper for leaked codex
# broker + queue-gateway socket-server orphans (issue #1567). Invoked ONCE by
# bridge-upgrade.sh during the migration phase, gated by a migration marker so
# it runs exactly once on the first upgrade that introduces it.
#
# Invocation contract (file-as-argv — NO heredoc-stdin into a subprocess;
# footgun #11 / scripts/lint-heredoc-ban.sh):
#   $1 = source_root   (the agent-bridge source checkout)
#   $2 = target_root   (the live install root being upgraded)
#   $3 = admin_id      (admin agent to enqueue the cleanup task to; may be "")
#   $4 = reap_optin    ("1" = actually reap; anything else = DRY-RUN report)
#
# Behavior:
#   * If the migration marker ($target_root/state/upgrade/codex-orphan-cleanup.ts)
#     already exists, no-op (idempotent — never re-runs on later upgrades).
#   * Detect leaked codex `app-server-broker.mjs` (+ child node app-server)
#     orphans reparented to init, and orphaned `bridge-queue-gateway.py
#     socket-server` processes whose --bridge-home no longer exists / is a
#     /tmp/agb-smoke-* dir. Detection logic lives in the Python sibling
#     codex-orphan-cleanup.py (testable, ps/kill heavy).
#   * DEFAULT = conservative: DRY-RUN report only (nothing killed) +
#     enqueue a high-priority admin cleanup task carrying the exact safe-kill
#     recipe, so the admin/operator confirms and executes. Pass reap_optin=1
#     (bridge-upgrade.sh maps this from --reap / AGENT_BRIDGE_REAP_CODEX_ORPHANS=1)
#     for unattended bounded reaping.
#   * Emit ONE redacted audit line (counts + pids, no secrets, no env).
#   * Drop the marker last so a mid-run failure re-attempts on the next upgrade.
#
# Output: redacted audit line(s) on stderr (via bridge_info / bridge_warn).
# Exit code: 0 on success (including "nothing found"); non-zero only when an
# opted-in reap could not signal a matched orphan. bridge-upgrade.sh treats a
# non-zero rc as a partial-failure warning, not a fatal abort.

set -uo pipefail

source_root="$1"
target_root="$2"
admin_id="${3:-}"
reap_optin="${4:-0}"

helper_py="$source_root/lib/upgrade-helpers/codex-orphan-cleanup.py"
marker="$target_root/state/upgrade/codex-orphan-cleanup.ts"

# Self-contained logging — deliberately does NOT source bridge-lib.sh.
#
# BLOCKER 1 (CI-reproduced): bridge-lib.sh runs the isolation-v2 layout resolver
# at source time, which `bridge_die`s / `exit`s on a `missing-marker(existing)`
# target layout (`Agent Bridge v0.8.0 requires isolation-v2 ... markerless`).
# That is a hard shell exit a `|| fallback` cannot catch, and sourcing it at all
# makes the one-shot short-circuit layout-DEPENDENT. This helper is a pure
# process-reaper: it only needs to log + shell out to python3 and the target's
# own `agent-bridge` CLI (which loads bridge-lib in its OWN process). So we log
# to stderr directly — exactly where bridge-upgrade.sh tails our output — and
# never depend on the target's runtime layout being loadable. The full report
# is also persisted to a state file, so nothing is lost vs. audit-log routing.
bridge_info() { printf '%s\n' "$*" >&2; }
bridge_warn() { printf '%s\n' "$*" >&2; }

# Idempotency: one-shot. After a successful run we drop the marker; a present
# marker short-circuits every later upgrade — with NO dependency on the target
# layout (the check is a plain file test, before any bridge-lib source).
# Operators who want to re-run can
# `rm "$BRIDGE_HOME/state/upgrade/codex-orphan-cleanup.ts"`.
if [[ -f "$marker" ]]; then
  bridge_info "codex-orphan-cleanup: marker present — already ran, skipping (#1567)"
  exit 0
fi

if [[ ! -f "$helper_py" ]]; then
  bridge_warn "codex-orphan-cleanup: detector $helper_py missing — skipping (#1567)"
  exit 0
fi

mode="scan"
if [[ "$reap_optin" == "1" ]]; then
  mode="reap"
fi

report_json=""
helper_rc=0
report_json="$(python3 "$helper_py" "$mode" --json 2>/dev/null)" || helper_rc=$?

if [[ -z "$report_json" ]]; then
  bridge_warn "codex-orphan-cleanup: detector produced no report (rc=$helper_rc) — skipping (#1567)"
  # Do NOT drop the marker on a detector failure — let the next upgrade retry.
  exit 0
fi

# Redacted audit line: counts + pids only (no --cwd/--bridge-home paths, which
# can carry operator usernames; no env). The audit JSON itself carries the
# full detail for the admin task body, written to a controlled state path.
audit_dir="$target_root/state/bridge-upgrade/codex-orphan-cleanup"
mkdir -p "$audit_dir" 2>/dev/null || true
ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
report_file="$audit_dir/report-$ts.json"
printf '%s\n' "$report_json" >"$report_file" 2>/dev/null || report_file=""

# Pull a redacted summary out of the report for the audit line. python3 parses
# the JSON we just wrote; file-as-argv (no heredoc-stdin).
summary_py="$source_root/lib/upgrade-helpers/codex-orphan-cleanup-summary.py"
audit_line=""
if [[ -f "$summary_py" ]]; then
  audit_line="$(printf '%s' "$report_json" | python3 "$summary_py" 2>/dev/null || true)"
fi
[[ -n "$audit_line" ]] || audit_line="codex-orphan-cleanup: report written ($report_file)"

# total count: 0 => nothing to do, drop marker and exit clean.
total="$(printf '%s' "$audit_line" | sed -n 's/.*total=\([0-9][0-9]*\).*/\1/p')"
[[ -n "$total" ]] || total=0

if [[ "$reap_optin" == "1" ]]; then
  bridge_info "codex-orphan-cleanup: REAP $audit_line (#1567)"
else
  bridge_info "codex-orphan-cleanup: DRY-RUN $audit_line (#1567)"
fi

if [[ "$total" == "0" ]]; then
  # Nothing leaked on this host — drop the marker so we never re-scan.
  printf '%s\n' "$ts" >"$marker" 2>/dev/null || true
  exit 0
fi

# Enqueue a high-priority admin cleanup task carrying the safe-kill recipe, so
# the admin/operator confirms + executes. Default posture per #1567: never
# auto-kill inside the upgrade — an active session could match. Only when
# reap_optin=1 did we actually reap above; the task then becomes an audit of
# what was reaped.
enqueue_rc=0
if [[ -n "$admin_id" && -x "$target_root/agent-bridge" ]]; then
  body_dir="$target_root/state/bridge-upgrade/codex-orphan-cleanup"
  mkdir -p "$body_dir" 2>/dev/null || true
  body_file="$body_dir/admin-task-$ts.md"
  {
    if [[ "$reap_optin" == "1" ]]; then
      printf '# Codex / queue-gateway orphan cleanup — REAPED on upgrade (#1567)\n\n'
      printf 'The upgrade ran with `--reap` opt-in and bounded-reaped the leaked orphans below.\n'
      printf 'This task is the audit trail. No further action is required unless a result is `permission-denied`.\n\n'
    else
      printf '# Codex / queue-gateway orphan cleanup — action required (#1567)\n\n'
      printf 'This upgrade DETECTED leaked orphaned processes but did NOT kill anything\n'
      printf '(conservative default — an active session could match). Confirm the list below,\n'
      printf 'then reap with the safe recipe.\n\n'
    fi
    printf -- '- detected_at: %s\n' "$ts"
    printf -- '- report: `%s`\n' "$report_file"
    printf -- '- %s\n\n' "$audit_line"
    printf '## Detected orphans\n\n```json\n'
    cat "$report_file" 2>/dev/null || printf '(report file unavailable)\n'
    printf '\n```\n\n'
    printf '## Safe reap recipe\n\n'
    printf 'Re-run the detector to confirm the list is unchanged, then reap:\n\n'
    printf '```bash\n'
    printf '# 1. Re-confirm (dry-run, nothing killed):\n'
    printf 'python3 %s scan\n\n' "$helper_py"
    printf '# 2. Reap the backlog (SIGTERM -> grace -> SIGKILL, PID-reuse-guarded):\n'
    printf 'python3 %s reap\n' "$helper_py"
    printf '```\n\n'
    printf 'The detector NEVER touches a broker whose worktree still exists, a\n'
    printf 'queue-gateway whose --bridge-home still resolves, or any process younger\n'
    printf 'than the idle threshold (default 2h). Close this task once the host is clean.\n'
  } >"$body_file" 2>/dev/null || body_file=""

  priority="high"
  title="[codex-orphan-cleanup] reaped $total leaked orphan(s) on upgrade (#1567)"
  if [[ "$reap_optin" != "1" ]]; then
    title="[codex-orphan-cleanup] $total leaked orphan(s) detected — confirm + reap (#1567)"
  fi

  if [[ -n "$body_file" ]]; then
    if ! "$target_root/agent-bridge" task create \
        --to "$admin_id" --from "$admin_id" --priority "$priority" \
        --title "$title" --body-file "$body_file" >/dev/null 2>&1; then
      enqueue_rc=1
      bridge_warn "codex-orphan-cleanup: could not enqueue admin cleanup task for $admin_id — recipe is in $body_file (#1567)"
    fi
  fi
else
  bridge_info "codex-orphan-cleanup: no admin agent configured — recipe is in $report_file (#1567)"
fi

# Drop the marker LAST so a crash before this point re-attempts next upgrade.
# Enqueue/reaper soft-failures are non-fatal: the host is already scanned and
# the report persisted; a marker prevents noisy re-scans on every later upgrade.
printf '%s\n' "$ts" >"$marker" 2>/dev/null || true

if [[ "$reap_optin" == "1" && "$helper_rc" != "0" ]]; then
  # An opted-in reap hit a permission error on at least one orphan.
  exit "$helper_rc"
fi
exit 0
