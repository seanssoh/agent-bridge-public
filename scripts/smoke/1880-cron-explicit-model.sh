#!/usr/bin/env bash
# scripts/smoke/1880-cron-explicit-model.sh — issue #1880 regression guard.
#
# Incident: the cron disposable child (`claude -p` / `codex exec`) inherited
# its model from the agent-home `.claude/settings.json` — the SAME file an
# interactive `/model` writes — because the cron runner passed NO explicit
# `--model` and jobs.json had no per-job model field. When the interactive
# model lost cron-token entitlement, EVERY cron child 404'd
# (`api_error_status: 404 ... selected model may not exist`) while the
# interactive session looked healthy (observed consecutive_errors=7).
#
# The fix (bridge-cron-runner.py::resolve_cron_child_model_effort) resolves an
# EXPLICIT model from stable sources only, in this precedence (highest first):
#   1. per-job        jobs.json job["model"] / job["effort"]
#   2. cron-default   jobs.json cronDefaults.{model,effort}
#   3. roster         BRIDGE_AGENT_MODEL/EFFORT (via bridge_agent_model accessor)
#   4. stable fallback BRIDGE_CRON_DEFAULT_MODEL / BRIDGE_CRON_DEFAULT_EFFORT env
# and run_claude / run_codex pass it to the child with an explicit `--model`.
# The interactive `.claude/settings.json` is NEVER consulted for the model.
#
# This smoke POISONS an interactive .claude/settings.json with a bogus model
# and proves the runner passes the EXPLICIT SAFE model (per precedence) to the
# child — not the poisoned interactive one.
#
# Footgun #11 (Bash 5.3.9 heredoc deadlock): the inline Python helper is built
# with `printf '%s\n'` to a tmp file and run as `python3 <file>` — no heredoc,
# no here-string, no process substitution.

set -euo pipefail

SMOKE_NAME="1880-cron-explicit-model"
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
# Tooth (a): precedence + poison immunity for resolve_cron_child_model_effort.
# A poisoned interactive settings.json must NOT influence the resolved model at
# any precedence tier; the per-job / cron-default tiers must win; the roster
# tier (stubbed) is used only when neither is set; an env fallback is the last
# resort and only when deliberately configured.
# ---------------------------------------------------------------------------
resolution_precedence_and_poison_immunity() {
  local helper="$SMOKE_TMP_ROOT/resolve_check.py"
  {
    printf '%s\n' 'import importlib.util, json, os, sys'
    printf '%s\n' 'from pathlib import Path'
    printf '%s\n' ''
    printf '%s\n' 'repo_root = os.environ["REPO_ROOT"]'
    printf '%s\n' 'tmp = Path(os.environ["TMP_ROOT"])'
    printf '%s\n' 'target = os.path.join(repo_root, "bridge-cron-runner.py")'
    printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_cron_runner", target)'
    printf '%s\n' 'module = importlib.util.module_from_spec(spec)'
    printf '%s\n' 'spec.loader.exec_module(module)'
    printf '%s\n' ''
    printf '%s\n' 'errors = []'
    printf '%s\n' ''
    printf '%s\n' '# POISON the interactive agent-home settings.json with a bogus model.'
    printf '%s\n' '# resolve_cron_child_model_effort must NEVER read this file, so this'
    printf '%s\n' '# value must NEVER appear in any resolved result.'
    printf '%s\n' 'POISON = "claude-poisoned-unavailable-9"'
    printf '%s\n' 'config_dir = tmp / "agent-home" / ".claude"'
    printf '%s\n' 'config_dir.mkdir(parents=True, exist_ok=True)'
    printf '%s\n' '(config_dir / "settings.json").write_text('
    printf '%s\n' '    json.dumps({"model": POISON, "effort": "poison-effort"}), encoding="utf-8")'
    printf '%s\n' ''
    printf '%s\n' '# Stub the roster accessor with a known value so the roster tier is'
    printf '%s\n' '# deterministic without sourcing the bash roster stack in the smoke.'
    printf '%s\n' 'ROSTER_MODEL = "claude-roster-stable-1"'
    printf '%s\n' 'ROSTER_EFFORT = "high"'
    printf '%s\n' 'module._roster_model_effort = lambda agent: (ROSTER_MODEL, ROSTER_EFFORT)'
    printf '%s\n' ''
    printf '%s\n' 'def write_jobs(job_extra=None, defaults=None):'
    printf '%s\n' '    job = {"id": "job-1", "name": "digest", "agentId": "mon"}'
    printf '%s\n' '    if job_extra:'
    printf '%s\n' '        job.update(job_extra)'
    printf '%s\n' '    payload = {"format": "agent-bridge-cron-v1", "jobs": [job]}'
    printf '%s\n' '    if defaults:'
    printf '%s\n' '        payload["cronDefaults"] = defaults'
    printf '%s\n' '    p = tmp / "jobs.json"'
    printf '%s\n' '    p.write_text(json.dumps(payload), encoding="utf-8")'
    printf '%s\n' '    return str(p)'
    printf '%s\n' ''
    printf '%s\n' 'def req(source_file):'
    printf '%s\n' '    return {"target_agent": "mon", "job_id": "job-1", "source_file": source_file,'
    printf '%s\n' '            "target_workdir": str(tmp)}'
    printf '%s\n' ''
    printf '%s\n' '# Tier 1 — per-job wins over cron-default + roster + env.'
    printf '%s\n' 'os.environ["BRIDGE_CRON_DEFAULT_MODEL"] = "claude-env-fallback-1"'
    printf '%s\n' 'jf = write_jobs(job_extra={"model": "claude-perjob-1", "effort": "xhigh"},'
    printf '%s\n' '                defaults={"model": "claude-default-1", "effort": "medium"})'
    printf '%s\n' 'model, effort, src = module.resolve_cron_child_model_effort(req(jf), "codex")'
    printf '%s\n' 'if model != "claude-perjob-1":'
    printf '%s\n' '    errors.append("tier1 per-job model not chosen: {0!r} src={1}".format(model, src))'
    printf '%s\n' 'if effort != "xhigh":'
    printf '%s\n' '    errors.append("tier1 per-job effort not chosen: {0!r}".format(effort))'
    printf '%s\n' 'if src != "per-job":'
    printf '%s\n' '    errors.append("tier1 source not per-job: {0!r}".format(src))'
    printf '%s\n' ''
    printf '%s\n' '# Tier 2 — cron-default wins when no per-job (over roster + env).'
    printf '%s\n' 'jf = write_jobs(defaults={"model": "claude-default-1", "effort": "medium"})'
    printf '%s\n' 'model, effort, src = module.resolve_cron_child_model_effort(req(jf), "codex")'
    printf '%s\n' 'if model != "claude-default-1" or src != "cron-default":'
    printf '%s\n' '    errors.append("tier2 cron-default not chosen: {0!r} src={1}".format(model, src))'
    printf '%s\n' 'if effort != "medium":'
    printf '%s\n' '    errors.append("tier2 cron-default effort not chosen: {0!r}".format(effort))'
    printf '%s\n' ''
    printf '%s\n' '# Tier 3 — roster wins when no per-job and no cron-default (over env).'
    printf '%s\n' 'jf = write_jobs()'
    printf '%s\n' 'model, effort, src = module.resolve_cron_child_model_effort(req(jf), "codex")'
    printf '%s\n' 'if model != ROSTER_MODEL or src != "roster":'
    printf '%s\n' '    errors.append("tier3 roster not chosen: {0!r} src={1}".format(model, src))'
    printf '%s\n' 'if effort != ROSTER_EFFORT:'
    printf '%s\n' '    errors.append("tier3 roster effort not chosen: {0!r}".format(effort))'
    printf '%s\n' ''
    printf '%s\n' '# Tier 4 — env fallback only when nothing else AND roster empty.'
    printf '%s\n' 'module._roster_model_effort = lambda agent: ("", "")'
    printf '%s\n' 'jf = write_jobs()'
    printf '%s\n' 'model, effort, src = module.resolve_cron_child_model_effort(req(jf), "codex")'
    printf '%s\n' 'if model != "claude-env-fallback-1" or src != "fallback":'
    printf '%s\n' '    errors.append("tier4 env-fallback not chosen: {0!r} src={1}".format(model, src))'
    printf '%s\n' ''
    printf '%s\n' '# POISON IMMUNITY — at EVERY tier the poisoned interactive model must be'
    printf '%s\n' '# absent from the resolved values.'
    printf '%s\n' 'module._roster_model_effort = lambda agent: (ROSTER_MODEL, ROSTER_EFFORT)'
    printf '%s\n' 'for label, je, df in ('
    printf '%s\n' '    ("per-job", {"model": "claude-perjob-1"}, None),'
    printf '%s\n' '    ("cron-default", None, {"model": "claude-default-1"}),'
    printf '%s\n' '    ("roster", None, None),'
    printf '%s\n' '):'
    printf '%s\n' '    jf = write_jobs(job_extra=je, defaults=df)'
    printf '%s\n' '    m, e, _s = module.resolve_cron_child_model_effort(req(jf), "claude")'
    printf '%s\n' '    if POISON in (m, e):'
    printf '%s\n' '        errors.append("POISON leaked into resolution at {0}: model={1!r} effort={2!r}".format(label, m, e))'
    printf '%s\n' '    if m == "poison-effort" or e == "poison-effort":'
    printf '%s\n' '        errors.append("poison effort leaked at {0}".format(label))'
    printf '%s\n' ''
    printf '%s\n' '# A missing / malformed jobs file must degrade to roster, never crash and'
    printf '%s\n' '# never read settings.json.'
    printf '%s\n' 'model, _e, src = module.resolve_cron_child_model_effort(req(str(tmp / "does-not-exist.json")), "codex")'
    printf '%s\n' 'if model != ROSTER_MODEL or src != "roster":'
    printf '%s\n' '    errors.append("missing jobs file did not degrade to roster: {0!r} src={1}".format(model, src))'
    printf '%s\n' ''
    printf '%s\n' '# An UNSAFE token in jobs.json (shell metachar) must be rejected, not passed.'
    printf '%s\n' 'jf = write_jobs(job_extra={"model": "evil; rm -rf /"})'
    printf '%s\n' 'model, _e, src = module.resolve_cron_child_model_effort(req(jf), "codex")'
    printf '%s\n' 'if model != ROSTER_MODEL:'
    printf '%s\n' '    errors.append("unsafe per-job model was not rejected: {0!r}".format(model))'
    printf '%s\n' ''
    printf '%s\n' 'if errors:'
    printf '%s\n' '    for x in errors:'
    printf '%s\n' '        print("[smoke][error] " + x, file=sys.stderr)'
    printf '%s\n' '    sys.exit(1)'
    printf '%s\n' 'print("[smoke] resolve_cron_child_model_effort precedence + poison immunity ok")'
  } >"$helper"

  REPO_ROOT="$REPO_ROOT" TMP_ROOT="$SMOKE_TMP_ROOT" "$PY_BIN" "$helper"
}

# ---------------------------------------------------------------------------
# Tooth (b): the runner passes the EXPLICIT safe model on the spawned child
# argv, NOT the poisoned interactive model. resolve_binary + subprocess.run are
# stubbed so no real claude/codex is spawned; we capture and assert the argv.
# ---------------------------------------------------------------------------
explicit_model_on_child_argv() {
  local helper="$SMOKE_TMP_ROOT/argv_check.py"
  {
    printf '%s\n' 'import importlib.util, json, os, subprocess, sys'
    printf '%s\n' 'from pathlib import Path'
    printf '%s\n' ''
    printf '%s\n' 'repo_root = os.environ["REPO_ROOT"]'
    printf '%s\n' 'tmp = Path(os.environ["TMP_ROOT"])'
    printf '%s\n' 'target = os.path.join(repo_root, "bridge-cron-runner.py")'
    printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_cron_runner", target)'
    printf '%s\n' 'module = importlib.util.module_from_spec(spec)'
    printf '%s\n' 'spec.loader.exec_module(module)'
    printf '%s\n' ''
    printf '%s\n' 'errors = []'
    printf '%s\n' 'POISON = "claude-poisoned-unavailable-9"'
    printf '%s\n' 'SAFE = "claude-perjob-safe-1"'
    printf '%s\n' ''
    printf '%s\n' '# Poison the interactive settings.json (must never reach the child argv).'
    printf '%s\n' 'config_dir = tmp / "agent-home2" / ".claude"'
    printf '%s\n' 'config_dir.mkdir(parents=True, exist_ok=True)'
    printf '%s\n' '(config_dir / "settings.json").write_text(json.dumps({"model": POISON}), encoding="utf-8")'
    printf '%s\n' ''
    printf '%s\n' '# jobs.json pins a SAFE per-job model.'
    printf '%s\n' 'jobs = {"format": "agent-bridge-cron-v1",'
    printf '%s\n' '        "jobs": [{"id": "job-1", "name": "digest", "agentId": "mon",'
    printf '%s\n' '                  "model": SAFE, "effort": "high"}]}'
    printf '%s\n' 'jf = tmp / "jobs2.json"'
    printf '%s\n' 'jf.write_text(json.dumps(jobs), encoding="utf-8")'
    printf '%s\n' ''
    printf '%s\n' 'workdir = tmp / "wd"'
    printf '%s\n' 'workdir.mkdir(exist_ok=True)'
    printf '%s\n' 'request = {"target_agent": "mon", "job_id": "job-1", "source_file": str(jf),'
    printf '%s\n' '           "target_workdir": str(workdir)}'
    printf '%s\n' ''
    printf '%s\n' '# Stub seams so no real claude/codex runs and no agent-env machinery fires.'
    printf '%s\n' 'module.resolve_binary = lambda name, env: "/usr/bin/true"'
    printf '%s\n' 'module.apply_claude_agent_env = lambda env, req, rf: None'
    printf '%s\n' 'module.command_for_run_as_user = lambda cmd, su, env: cmd'
    printf '%s\n' 'module.validate_claude_keychain_free_auth = lambda *a, **k: None'
    printf '%s\n' 'captured = {}'
    printf '%s\n' 'def fake_run(cmd, **kw):'
    printf '%s\n' '    captured["cmd"] = cmd'
    printf '%s\n' '    return subprocess.CompletedProcess(cmd, 0, "{}", "")'
    printf '%s\n' 'module.subprocess.run = fake_run'
    printf '%s\n' ''
    printf '%s\n' '# Claude path: argv must carry --model SAFE, and NEVER the poison.'
    printf '%s\n' 'cmd, _completed = module.run_claude(request, "do the job", 10)'
    printf '%s\n' 'if "--model" not in cmd:'
    printf '%s\n' '    errors.append("run_claude argv has no --model flag: {0!r}".format(cmd))'
    printf '%s\n' 'else:'
    printf '%s\n' '    mi = cmd.index("--model")'
    printf '%s\n' '    if cmd[mi + 1] != SAFE:'
    printf '%s\n' '        errors.append("run_claude --model not SAFE: {0!r}".format(cmd[mi + 1]))'
    printf '%s\n' 'if POISON in cmd:'
    printf '%s\n' '    errors.append("run_claude argv contains the poisoned interactive model: {0!r}".format(cmd))'
    printf '%s\n' '# The model flag must precede the trailing positional prompt.'
    printf '%s\n' 'if cmd and cmd[-1] != "do the job":'
    printf '%s\n' '    errors.append("run_claude prompt is not the trailing positional: {0!r}".format(cmd[-1]))'
    printf '%s\n' ''
    printf '%s\n' '# Codex path: argv must carry --model SAFE + -c model_reasoning_effort=high.'
    printf '%s\n' 'schema = tmp / "schema.json"'
    printf '%s\n' 'schema.write_text("{}", encoding="utf-8")'
    printf '%s\n' 'cmd2, _c2 = module.run_codex(request, "do the job", schema, 10)'
    printf '%s\n' 'if "--model" not in cmd2 or cmd2[cmd2.index("--model") + 1] != SAFE:'
    printf '%s\n' '    errors.append("run_codex --model not SAFE: {0!r}".format(cmd2))'
    printf '%s\n' 'if "model_reasoning_effort=high" not in cmd2:'
    printf '%s\n' '    errors.append("run_codex missing reasoning effort override: {0!r}".format(cmd2))'
    printf '%s\n' 'if POISON in cmd2:'
    printf '%s\n' '    errors.append("run_codex argv contains the poisoned interactive model: {0!r}".format(cmd2))'
    printf '%s\n' 'if cmd2 and cmd2[-1] != "do the job":'
    printf '%s\n' '    errors.append("run_codex prompt is not the trailing positional: {0!r}".format(cmd2[-1]))'
    printf '%s\n' ''
    printf '%s\n' 'if errors:'
    printf '%s\n' '    for x in errors:'
    printf '%s\n' '        print("[smoke][error] " + x, file=sys.stderr)'
    printf '%s\n' '    sys.exit(1)'
    printf '%s\n' 'print("[smoke] cron child argv carries the explicit SAFE model, not the poisoned interactive one")'
  } >"$helper"

  REPO_ROOT="$REPO_ROOT" TMP_ROOT="$SMOKE_TMP_ROOT" "$PY_BIN" "$helper"
}

# ---------------------------------------------------------------------------
# Tooth (c): FAIL CLOSED when no stable model source resolves (#1880 r2).
# With per-job + cronDefaults + roster + BRIDGE_CRON_DEFAULT_MODEL ALL empty and
# the interactive settings.json POISONED, run_claude must NOT spawn an unmodeled
# child (which would inherit the poisoned settings.json model). It must raise an
# actionable error naming the fix, and subprocess.run must NEVER be called.
# ---------------------------------------------------------------------------
fail_closed_no_stable_model_source() {
  local helper="$SMOKE_TMP_ROOT/fail_closed_check.py"
  {
    printf '%s\n' 'import importlib.util, json, os, subprocess, sys'
    printf '%s\n' 'from pathlib import Path'
    printf '%s\n' ''
    printf '%s\n' 'repo_root = os.environ["REPO_ROOT"]'
    printf '%s\n' 'tmp = Path(os.environ["TMP_ROOT"])'
    printf '%s\n' 'target = os.path.join(repo_root, "bridge-cron-runner.py")'
    printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_cron_runner", target)'
    printf '%s\n' 'module = importlib.util.module_from_spec(spec)'
    printf '%s\n' 'spec.loader.exec_module(module)'
    printf '%s\n' ''
    printf '%s\n' 'errors = []'
    printf '%s\n' 'POISON = "claude-poisoned-unavailable-9"'
    printf '%s\n' ''
    printf '%s\n' '# POISON the interactive settings.json — the ONLY model source present.'
    printf '%s\n' 'config_dir = tmp / "agent-home3" / ".claude"'
    printf '%s\n' 'config_dir.mkdir(parents=True, exist_ok=True)'
    printf '%s\n' '(config_dir / "settings.json").write_text(json.dumps({"model": POISON}), encoding="utf-8")'
    printf '%s\n' ''
    printf '%s\n' '# jobs.json with NO per-job model and NO cronDefaults.'
    printf '%s\n' 'jobs = {"format": "agent-bridge-cron-v1",'
    printf '%s\n' '        "jobs": [{"id": "job-1", "name": "digest", "agentId": "mon"}]}'
    printf '%s\n' 'jf = tmp / "jobs3.json"'
    printf '%s\n' 'jf.write_text(json.dumps(jobs), encoding="utf-8")'
    printf '%s\n' ''
    printf '%s\n' 'workdir = tmp / "wd3"'
    printf '%s\n' 'workdir.mkdir(exist_ok=True)'
    printf '%s\n' 'request = {"target_agent": "mon", "job_id": "job-1", "source_file": str(jf),'
    printf '%s\n' '           "target_workdir": str(workdir)}'
    printf '%s\n' ''
    printf '%s\n' '# Empty roster + empty env fallback => NO stable source at all.'
    printf '%s\n' 'module._roster_model_effort = lambda agent: ("", "")'
    printf '%s\n' 'os.environ.pop("BRIDGE_CRON_DEFAULT_MODEL", None)'
    printf '%s\n' 'os.environ.pop("BRIDGE_CRON_DEFAULT_EFFORT", None)'
    printf '%s\n' ''
    printf '%s\n' '# subprocess.run must NEVER fire — assert it stays uncalled. Stub it to'
    printf '%s\n' '# record any (forbidden) call and to fail loudly if one happens.'
    printf '%s\n' 'module.resolve_binary = lambda name, env: "/usr/bin/true"'
    printf '%s\n' 'module.apply_claude_agent_env = lambda env, req, rf: None'
    printf '%s\n' 'module.command_for_run_as_user = lambda cmd, su, env: cmd'
    printf '%s\n' 'spawn_calls = []'
    printf '%s\n' 'def forbidden_run(cmd, **kw):'
    printf '%s\n' '    spawn_calls.append(cmd)'
    printf '%s\n' '    return subprocess.CompletedProcess(cmd, 0, "{}", "")'
    printf '%s\n' 'module.subprocess.run = forbidden_run'
    printf '%s\n' ''
    printf '%s\n' '# run_claude must FAIL CLOSED: raise, do NOT build an unmodeled argv,'
    printf '%s\n' '# do NOT spawn.'
    printf '%s\n' 'raised = None'
    printf '%s\n' 'try:'
    printf '%s\n' '    module.run_claude(request, "do the job", 10)'
    printf '%s\n' 'except module.CronChildModelUnresolvedError as exc:'
    printf '%s\n' '    raised = exc'
    printf '%s\n' 'except Exception as exc:'
    printf '%s\n' '    errors.append("run_claude raised wrong type: {0!r}".format(exc))'
    printf '%s\n' ''
    printf '%s\n' 'if raised is None:'
    printf '%s\n' '    errors.append("run_claude did NOT fail closed on zero stable model source")'
    printf '%s\n' 'else:'
    printf '%s\n' '    msg = str(raised)'
    printf '%s\n' '    if "--cron-default-model" not in msg or "BRIDGE_AGENT_MODEL" not in msg:'
    printf '%s\n' '        errors.append("fail-closed error not actionable (missing fix hint): {0!r}".format(msg))'
    printf '%s\n' '    if POISON in msg:'
    printf '%s\n' '        errors.append("fail-closed error leaked the poisoned model: {0!r}".format(msg))'
    printf '%s\n' ''
    printf '%s\n' 'if spawn_calls:'
    printf '%s\n' '    errors.append("FORBIDDEN: an unmodeled Claude child was spawned: {0!r}".format(spawn_calls))'
    printf '%s\n' ''
    printf '%s\n' '# A codex child with no stable source is NOT forced to fail closed (codex'
    printf '%s\n' '# has no settings.json model-inherit coupling); it simply omits --model.'
    printf '%s\n' 'schema = tmp / "schema3.json"'
    printf '%s\n' 'schema.write_text("{}", encoding="utf-8")'
    printf '%s\n' 'cmd2, _c2 = module.run_codex(request, "do the job", schema, 10)'
    printf '%s\n' 'if "--model" in cmd2:'
    printf '%s\n' '    errors.append("run_codex unexpectedly added --model with no source: {0!r}".format(cmd2))'
    printf '%s\n' 'if POISON in cmd2:'
    printf '%s\n' '    errors.append("run_codex argv leaked the poisoned model: {0!r}".format(cmd2))'
    printf '%s\n' ''
    printf '%s\n' 'if errors:'
    printf '%s\n' '    for x in errors:'
    printf '%s\n' '        print("[smoke][error] " + x, file=sys.stderr)'
    printf '%s\n' '    sys.exit(1)'
    printf '%s\n' 'print("[smoke] Claude cron child fails closed with an actionable error; no unmodeled spawn")'
  } >"$helper"

  REPO_ROOT="$REPO_ROOT" TMP_ROOT="$SMOKE_TMP_ROOT" "$PY_BIN" "$helper"
}

main() {
  smoke_require_cmd "$PY_BIN"
  smoke_make_temp_root "$SMOKE_NAME"

  smoke_run "resolve precedence (per-job > cron-default > roster > env) + poison immunity" resolution_precedence_and_poison_immunity
  smoke_run "cron child argv carries explicit safe model, not poisoned settings.json" explicit_model_on_child_argv
  smoke_run "Claude cron child fails closed on zero stable model source (no unmodeled spawn)" fail_closed_no_stable_model_source

  smoke_log "passed"
}

main "$@"
