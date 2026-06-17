#!/usr/bin/env bash
# scripts/smoke/1943-cron-unmodeled-warn-on-upgrade.sh — issue #1943 (cm-prod F3).
#
# Incident: after upgrade, existing Claude crons that relied on inheriting the
# interactive model are SILENTLY refused by the #1880 gate
# (`no stable model source ... refusing to spawn an unmodeled Claude child`).
# The queue floods with error followups and the operator has NO warning + NO
# remediation. The #1880 gate is correct; the regression is the SILENT breakage.
#
# The fix (lib/upgrade-helpers/cron-unmodeled-claude-warn.py, invoked from
# bridge-upgrade.sh's [upgrade-complete] task-body composer) detects Claude
# crons the #1880 gate would refuse and emits a LOUD, actionable warning at
# upgrade time. It is strictly READ-ONLY: it never auto-pins a model (a
# usage/entitlement decision the operator must make) and never fails the
# upgrade. It mirrors the runner's exact precedence by importing the canonical
# resolve_cron_child_model_effort + interactive_settings_model_for_request so
# the warning can never drift from the gate it predicts.
#
# This smoke pins the warn / no-warn matrix:
#   (1) Claude cron, NO resolvable model, interactive model pinned -> WARNED.
#   (2) Claude cron, per-job model set                            -> NOT warned.
#   (3) Claude cron, NO model, NO interactive model               -> NOT warned.
#   (4) Codex cron, NO resolvable model, interactive model pinned -> NOT warned
#       (codex never hits the #1880 settings.json coupling).
#   (5) Disabled Claude cron that would otherwise warn            -> NOT warned.
#   (6) Empty / no-affected jobs file                             -> empty out.
#
# Footgun #11 (Bash 5.3.9 heredoc deadlock): the inline Python helper is built
# with `printf '%s\n'` to a tmp file and run as `python3 <file>` — no heredoc,
# no here-string, no process substitution.

set -euo pipefail

SMOKE_NAME="1943-cron-unmodeled-warn-on-upgrade"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The detector's warn / no-warn decision matrix, exercised in-process with the
# roster-engine map and the runner's interactive-settings probe both STUBBED so
# the smoke is hermetic (no bash roster source, no real agent-home settings.json
# lookup). The jobs-file precedence (per-job model) is exercised through the REAL
# resolve_cron_child_model_effort import, so a precedence change in the runner
# would surface here.
# ---------------------------------------------------------------------------
warn_matrix() {
  local helper="$SMOKE_TMP_ROOT/warn_matrix.py"
  {
    printf '%s\n' 'import importlib.util, io, json, os, sys'
    printf '%s\n' 'from contextlib import redirect_stdout'
    printf '%s\n' 'from pathlib import Path'
    printf '%s\n' ''
    printf '%s\n' 'repo_root = os.environ["REPO_ROOT"]'
    printf '%s\n' 'tmp = Path(os.environ["TMP_ROOT"])'
    printf '%s\n' 'helper_path = os.path.join(repo_root, "lib", "upgrade-helpers", "cron-unmodeled-claude-warn.py")'
    printf '%s\n' 'spec = importlib.util.spec_from_file_location("cron_unmodeled_warn", helper_path)'
    printf '%s\n' 'mod = importlib.util.module_from_spec(spec)'
    printf '%s\n' 'spec.loader.exec_module(mod)'
    printf '%s\n' ''
    printf '%s\n' 'errors = []'
    printf '%s\n' ''
    printf '%s\n' '# Roster engine map (stub): claude agents vs a codex agent.'
    printf '%s\n' 'ENGINES = {"mon": "claude", "mon2": "claude", "mon3": "claude",'
    printf '%s\n' '           "cdx": "codex", "off": "claude"}'
    printf '%s\n' 'mod._roster_engines = lambda bridge_root, agents: {a: ENGINES.get(a, "") for a in agents}'
    printf '%s\n' ''
    printf '%s\n' '# Interactive settings.json model probe (stub): which agents have a'
    printf '%s\n' '# model pinned in their interactive .claude/settings.json. The detector'
    printf '%s\n' '# imports the runner and calls runner.interactive_settings_model_for_request,'
    printf '%s\n' '# so we patch that on the imported runner module the detector loaded.'
    printf '%s\n' 'SETTINGS_MODEL = {"mon": "claude-interactive-1", "mon3": "",'
    printf '%s\n' '                  "cdx": "claude-interactive-1", "off": "claude-interactive-1"}'
    printf '%s\n' 'real_load_runner = mod._load_runner'
    printf '%s\n' 'def patched_load_runner(bridge_root):'
    printf '%s\n' '    runner = real_load_runner(bridge_root)'
    printf '%s\n' '    if runner is not None:'
    printf '%s\n' '        runner.interactive_settings_model_for_request = ('
    printf '%s\n' '            lambda req: SETTINGS_MODEL.get(str(req.get("target_agent") or ""), ""))'
    printf '%s\n' '        # Hermeticity: stub the runner roster leg to empty so'
    printf '%s\n' '        # resolve_cron_child_model_effort cannot pick up a live roster'
    printf '%s\n' '        # BRIDGE_AGENT_MODEL for a fixture agent (e.g. "mon") on the host'
    printf '%s\n' '        # running the smoke. The jobs-file precedence legs (per-job /'
    printf '%s\n' '        # cronDefaults) stay REAL so a precedence change still surfaces.'
    printf '%s\n' '        runner._roster_model_effort = lambda agent: ("", "")'
    printf '%s\n' '    return runner'
    printf '%s\n' 'mod._load_runner = patched_load_runner'
    printf '%s\n' ''
    printf '%s\n' 'def run_detector(jobs):'
    printf '%s\n' '    jf = tmp / "jobs.json"'
    printf '%s\n' '    jf.write_text(json.dumps(jobs), encoding="utf-8")'
    printf '%s\n' '    saved_argv = sys.argv'
    printf '%s\n' '    sys.argv = ["cron-unmodeled-warn", str(jf), repo_root]'
    printf '%s\n' '    buf = io.StringIO()'
    printf '%s\n' '    try:'
    printf '%s\n' '        with redirect_stdout(buf):'
    printf '%s\n' '            try:'
    printf '%s\n' '                mod.main()'
    printf '%s\n' '            except SystemExit:'
    printf '%s\n' '                pass'
    printf '%s\n' '    finally:'
    printf '%s\n' '        sys.argv = saved_argv'
    printf '%s\n' '    return buf.getvalue()'
    printf '%s\n' ''
    printf '%s\n' '# Make sure no env fallback model is set (would pass the gate for all).'
    printf '%s\n' 'os.environ.pop("BRIDGE_CRON_DEFAULT_MODEL", None)'
    printf '%s\n' ''
    printf '%s\n' '# (1) Claude cron, no model anywhere, interactive model pinned -> WARNED.'
    printf '%s\n' 'jobs = {"format": "agent-bridge-cron-v1", "jobs": ['
    printf '%s\n' '    {"id": "job-warn", "name": "digest-warn", "agentId": "mon", "enabled": True}]}'
    printf '%s\n' 'out = run_detector(jobs)'
    printf '%s\n' 'if not out.strip():'
    printf '%s\n' '    errors.append("(1) expected a warning for unmodeled Claude cron, got empty output")'
    printf '%s\n' 'else:'
    printf '%s\n' '    if "#1880" not in out or "#1943" not in out:'
    printf '%s\n' '        errors.append("(1) warning missing issue refs: {0!r}".format(out))'
    printf '%s\n' '    if "job-warn" not in out:'
    printf '%s\n' '        errors.append("(1) warning did not list the affected job id: {0!r}".format(out))'
    printf '%s\n' '    if "digest-warn" not in out:'
    printf '%s\n' '        errors.append("(1) warning did not list the affected job name: {0!r}".format(out))'
    printf '%s\n' '    if "mon" not in out:'
    printf '%s\n' '        errors.append("(1) warning did not list the affected agent: {0!r}".format(out))'
    printf '%s\n' '    # Remediation must be present and must NOT instruct auto-pinning the'
    printf '%s\n' '    # interactive model (the #1880 coupling).'
    printf '%s\n' '    if "--model" not in out and "cron-default-model" not in out:'
    printf '%s\n' '        errors.append("(1) warning missing remediation command: {0!r}".format(out))'
    printf '%s\n' ''
    printf '%s\n' '# (2) Claude cron WITH a per-job model -> resolves -> NOT warned.'
    printf '%s\n' 'jobs = {"format": "agent-bridge-cron-v1", "jobs": ['
    printf '%s\n' '    {"id": "job-ok", "name": "digest-ok", "agentId": "mon",'
    printf '%s\n' '     "enabled": True, "model": "claude-sonnet-4-6"}]}'
    printf '%s\n' 'out = run_detector(jobs)'
    printf '%s\n' 'if out.strip():'
    printf '%s\n' '    errors.append("(2) a Claude cron with a per-job model must NOT warn: {0!r}".format(out))'
    printf '%s\n' ''
    printf '%s\n' '# (2b) Claude cron with cronDefaults.model -> resolves -> NOT warned.'
    printf '%s\n' 'jobs = {"format": "agent-bridge-cron-v1",'
    printf '%s\n' '        "cronDefaults": {"model": "claude-sonnet-4-6"},'
    printf '%s\n' '        "jobs": [{"id": "job-okd", "name": "digest-okd", "agentId": "mon", "enabled": True}]}'
    printf '%s\n' 'out = run_detector(jobs)'
    printf '%s\n' 'if out.strip():'
    printf '%s\n' '    errors.append("(2b) a Claude cron with cronDefaults.model must NOT warn: {0!r}".format(out))'
    printf '%s\n' ''
    printf '%s\n' '# (3) Claude cron, no model AND no interactive model pinned -> NOT warned'
    printf '%s\n' '#     (no #1880 coupling exists; account default applies as before).'
    printf '%s\n' 'jobs = {"format": "agent-bridge-cron-v1", "jobs": ['
    printf '%s\n' '    {"id": "job-nm", "name": "digest-nm", "agentId": "mon3", "enabled": True}]}'
    printf '%s\n' 'out = run_detector(jobs)'
    printf '%s\n' 'if out.strip():'
    printf '%s\n' '    errors.append("(3) no interactive model => no coupling => must NOT warn: {0!r}".format(out))'
    printf '%s\n' ''
    printf '%s\n' '# (4) Codex cron, no model, interactive model pinned -> NOT warned'
    printf '%s\n' '#     (run_codex never reads settings.json; no #1880 gate).'
    printf '%s\n' 'jobs = {"format": "agent-bridge-cron-v1", "jobs": ['
    printf '%s\n' '    {"id": "job-cdx", "name": "digest-cdx", "agentId": "cdx", "enabled": True}]}'
    printf '%s\n' 'out = run_detector(jobs)'
    printf '%s\n' 'if out.strip():'
    printf '%s\n' '    errors.append("(4) a codex cron must NOT warn (no settings.json coupling): {0!r}".format(out))'
    printf '%s\n' ''
    printf '%s\n' '# (5) DISABLED Claude cron that would otherwise warn -> NOT warned.'
    printf '%s\n' 'jobs = {"format": "agent-bridge-cron-v1", "jobs": ['
    printf '%s\n' '    {"id": "job-off", "name": "digest-off", "agentId": "off", "enabled": False}]}'
    printf '%s\n' 'out = run_detector(jobs)'
    printf '%s\n' 'if out.strip():'
    printf '%s\n' '    errors.append("(5) a disabled cron must NOT warn: {0!r}".format(out))'
    printf '%s\n' ''
    printf '%s\n' '# (6) Mixed file: only the affected Claude job(s) appear; the resolved /'
    printf '%s\n' '#     codex / no-interactive jobs do NOT. Proves non-vacuous filtering.'
    printf '%s\n' 'jobs = {"format": "agent-bridge-cron-v1", "jobs": ['
    printf '%s\n' '    {"id": "job-warn", "name": "digest-warn", "agentId": "mon", "enabled": True},'
    printf '%s\n' '    {"id": "job-ok", "name": "digest-ok", "agentId": "mon", "enabled": True, "model": "claude-sonnet-4-6"},'
    printf '%s\n' '    {"id": "job-cdx", "name": "digest-cdx", "agentId": "cdx", "enabled": True}]}'
    printf '%s\n' 'out = run_detector(jobs)'
    printf '%s\n' 'if "job-warn" not in out:'
    printf '%s\n' '    errors.append("(6) mixed file dropped the affected job: {0!r}".format(out))'
    printf '%s\n' 'if "job-ok" in out or "job-cdx" in out:'
    printf '%s\n' '    errors.append("(6) mixed file warned a non-affected job: {0!r}".format(out))'
    printf '%s\n' ''
    printf '%s\n' '# (7) Empty jobs file -> empty output, exit 0.'
    printf '%s\n' 'out = run_detector({"format": "agent-bridge-cron-v1", "jobs": []})'
    printf '%s\n' 'if out.strip():'
    printf '%s\n' '    errors.append("(7) empty jobs file must produce no warning: {0!r}".format(out))'
    printf '%s\n' ''
    printf '%s\n' 'if errors:'
    printf '%s\n' '    for x in errors:'
    printf '%s\n' '        print("[smoke][error] " + x, file=sys.stderr)'
    printf '%s\n' '    sys.exit(1)'
    printf '%s\n' 'print("[smoke] unmodeled-Claude-cron warn/no-warn matrix ok")'
  } >"$helper"

  REPO_ROOT="$REPO_ROOT" TMP_ROOT="$SMOKE_TMP_ROOT" "$PY_BIN" "$helper"
}

# ---------------------------------------------------------------------------
# Robustness tooth: the detector is best-effort — a missing / unreadable / junk
# jobs file, or a missing argv, must NEVER raise and must produce empty output
# (so a cron-scan failure cannot fail the upgrade).
# ---------------------------------------------------------------------------
best_effort_degradation() {
  local helper="$SMOKE_TMP_ROOT/degrade.py"
  {
    printf '%s\n' 'import os, subprocess, sys'
    printf '%s\n' 'from pathlib import Path'
    printf '%s\n' ''
    printf '%s\n' 'repo_root = os.environ["REPO_ROOT"]'
    printf '%s\n' 'tmp = Path(os.environ["TMP_ROOT"])'
    printf '%s\n' 'helper = os.path.join(repo_root, "lib", "upgrade-helpers", "cron-unmodeled-claude-warn.py")'
    printf '%s\n' 'errors = []'
    printf '%s\n' ''
    printf '%s\n' 'def run(args):'
    printf '%s\n' '    return subprocess.run([sys.executable, helper, *args],'
    printf '%s\n' '                          capture_output=True, text=True)'
    printf '%s\n' ''
    printf '%s\n' '# Missing jobs file -> rc 0, empty stdout.'
    printf '%s\n' 'r = run([str(tmp / "does-not-exist.json"), repo_root])'
    printf '%s\n' 'if r.returncode != 0 or r.stdout.strip():'
    printf '%s\n' '    errors.append("missing jobs file: rc={0} out={1!r}".format(r.returncode, r.stdout))'
    printf '%s\n' ''
    printf '%s\n' '# Junk (non-JSON) jobs file -> rc 0, empty stdout.'
    printf '%s\n' 'junk = tmp / "junk.json"'
    printf '%s\n' 'junk.write_text("this is not json {", encoding="utf-8")'
    printf '%s\n' 'r = run([str(junk), repo_root])'
    printf '%s\n' 'if r.returncode != 0 or r.stdout.strip():'
    printf '%s\n' '    errors.append("junk jobs file: rc={0} out={1!r}".format(r.returncode, r.stdout))'
    printf '%s\n' ''
    printf '%s\n' '# No argv at all -> rc 0, empty stdout.'
    printf '%s\n' 'r = run([])'
    printf '%s\n' 'if r.returncode != 0 or r.stdout.strip():'
    printf '%s\n' '    errors.append("no argv: rc={0} out={1!r}".format(r.returncode, r.stdout))'
    printf '%s\n' ''
    printf '%s\n' 'if errors:'
    printf '%s\n' '    for x in errors:'
    printf '%s\n' '        print("[smoke][error] " + x, file=sys.stderr)'
    printf '%s\n' '    sys.exit(1)'
    printf '%s\n' 'print("[smoke] best-effort degradation (missing/junk/no-argv) never fails ok")'
  } >"$helper"

  REPO_ROOT="$REPO_ROOT" TMP_ROOT="$SMOKE_TMP_ROOT" "$PY_BIN" "$helper"
}

main() {
  smoke_require_cmd "$PY_BIN"
  smoke_make_temp_root "$SMOKE_NAME"

  smoke_run "warn iff unmodeled Claude cron with interactive model pinned; never auto-pin" warn_matrix
  smoke_run "best-effort degradation: missing/junk/no-argv jobs file never fails the upgrade" best_effort_degradation

  smoke_log "passed"
}

main "$@"
