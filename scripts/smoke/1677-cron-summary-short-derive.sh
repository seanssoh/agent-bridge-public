#!/usr/bin/env bash
# scripts/smoke/1677-cron-summary-short-derive.sh — v0.16.3 #1677 guard.
#
# Regression guard for the cron-runner `summary_short` data-loss fix.
#
# Before this patch, bridge-cron-runner.py's validate_result() raised a fatal
# ValueError when a non-silent delivery_intent carried a schema-valid
# summary_short=null (or empty, or overlong). The caller (cmd_run) treats that
# raise as a fatal result-validation failure and substitutes a GENERIC error
# envelope (summary=error text, findings=[], actions_taken=[],
# recommended_next_steps=["Inspect stdout.log"]) — discarding the child's
# ENTIRE valid signal, not just the missing routing digest. The LLM child
# emits null ~25% of the time (nondeterminism), so ~1-in-4 cron signals were
# lost irrecoverably.
#
# The fix: derive summary_short from the already-required non-empty `summary`
# (first non-empty line, whitespace-normalized) and VISIBLY truncate
# (text[:197] + "...") to stay within the ≤200 contract, instead of raising —
# preserving the rest of the payload. SCOPE FENCE: empty `summary` and every
# other validation failure (e.g. bad forward_target) stay fatal exactly as
# before. A normalization note is surfaced on result.json
# (`summary_short_normalized`) and a stderr WARNING.
#
# This smoke fails the build if a future PR re-introduces the fatal raise, the
# silent (markerless) truncation, the empty-summary-non-fatal regression, or
# the scope-fence leak (bad forward_target becoming non-fatal).
#
# Footgun #11 (Bash 5.3.9 heredoc deadlock): this smoke writes its inline
# Python helper via `printf` to a tmp file and runs `python3 <file>` — no
# heredoc, no here-string.

set -euo pipefail

SMOKE_NAME="1677-cron-summary-short-derive"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root

HELPER="$SMOKE_TMP_ROOT/derive_check.py"

# Build the helper line-by-line via printf — no heredoc / no here-string.
{
  printf '%s\n' 'import importlib.util, os, sys'
  printf '%s\n' ''
  printf '%s\n' 'repo_root = os.environ["REPO_ROOT"]'
  printf '%s\n' 'target = os.path.join(repo_root, "bridge-cron-runner.py")'
  printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_cron_runner", target)'
  printf '%s\n' 'module = importlib.util.module_from_spec(spec)'
  printf '%s\n' 'spec.loader.exec_module(module)'
  printf '%s\n' 'validate_result = module.validate_result'
  printf '%s\n' 'MAX = module.SUMMARY_SHORT_MAX'
  printf '%s\n' ''
  printf '%s\n' 'errors = []'
  printf '%s\n' ''
  printf '%s\n' 'def base(**over):'
  printf '%s\n' '    p = {'
  printf '%s\n' '        "status": "completed",'
  printf '%s\n' '        "summary": "First real digest line.\nSecond extra line.",'
  printf '%s\n' '        "findings": ["f1"],'
  printf '%s\n' '        "actions_taken": ["a1"],'
  printf '%s\n' '        "needs_human_followup": True,'
  printf '%s\n' '        "recommended_next_steps": ["n1"],'
  printf '%s\n' '        "artifacts": ["x"],'
  printf '%s\n' '        "confidence": "high",'
  printf '%s\n' '        "delivery_intent": "main_session_only",'
  printf '%s\n' '        "forward_target": None,'
  printf '%s\n' '        "summary_short": None,'
  printf '%s\n' '        "channel_relay": None,'
  printf '%s\n' '    }'
  printf '%s\n' '    p.update(over)'
  printf '%s\n' '    return p'
  printf '%s\n' ''
  printf '%s\n' 'FT = {"channel": "telegram", "target_ref": "@alerts", "format": "text"}'
  printf '%s\n' ''
  printf '%s\n' '# Tooth 1a: main_session_only + summary_short=None preserves the WHOLE'
  printf '%s\n' '# payload and fills a derived summary_short (first non-empty summary line).'
  printf '%s\n' 'r = validate_result(base(delivery_intent="main_session_only", summary_short=None))'
  printf '%s\n' 'if r.get("summary_short") != "First real digest line.":'
  printf '%s\n' '    errors.append("1a: expected first-line derive, got {0!r}".format(r.get("summary_short")))'
  printf '%s\n' 'if r.get("findings") != ["f1"] or r.get("actions_taken") != ["a1"]:'
  printf '%s\n' '    errors.append("1a: payload not preserved (findings/actions dropped)")'
  printf '%s\n' 'if r.get("recommended_next_steps") != ["n1"]:'
  printf '%s\n' '    errors.append("1a: recommended_next_steps dropped")'
  printf '%s\n' 'if not r.get("summary_short_normalized"):'
  printf '%s\n' '    errors.append("1a: missing summary_short_normalized note")'
  printf '%s\n' ''
  printf '%s\n' '# Tooth 1b: forward_to_user + empty summary_short derives AND preserves a'
  printf '%s\n' '# valid forward_target (routing intact).'
  printf '%s\n' 'r = validate_result(base(delivery_intent="forward_to_user", summary_short="   ", forward_target=FT))'
  printf '%s\n' 'if r.get("summary_short") != "First real digest line.":'
  printf '%s\n' '    errors.append("1b: expected derive on empty, got {0!r}".format(r.get("summary_short")))'
  printf '%s\n' 'if r.get("forward_target") != FT:'
  printf '%s\n' '    errors.append("1b: forward_target not preserved")'
  printf '%s\n' ''
  printf '%s\n' '# Tooth 2: a long DERIVED summary_short is VISIBLY truncated (ends with the'
  printf '%s\n' '# marker) and stays within SUMMARY_SHORT_MAX.'
  printf '%s\n' 'r = validate_result(base(delivery_intent="main_session_only", summary_short=None, summary="Z" * 500))'
  printf '%s\n' 'ss = r.get("summary_short") or ""'
  printf '%s\n' 'if len(ss) > MAX:'
  printf '%s\n' '    errors.append("2: derived summary_short exceeds MAX ({0} > {1})".format(len(ss), MAX))'
  printf '%s\n' 'if not ss.endswith("..."):'
  printf '%s\n' '    errors.append("2: truncation not visible (no ... marker): {0!r}".format(ss[-6:]))'
  printf '%s\n' 'if "truncat" not in (r.get("summary_short_normalized") or ""):'
  printf '%s\n' '    errors.append("2: missing truncation note")'
  printf '%s\n' ''
  printf '%s\n' '# Tooth 3: an overlong CHILD-provided summary_short is truncated rather than'
  printf '%s\n' '# raising (same data-loss class; preserves the ≤200 downstream contract).'
  printf '%s\n' 'r = validate_result(base(delivery_intent="main_session_only", summary_short="Q" * 500))'
  printf '%s\n' 'ss = r.get("summary_short") or ""'
  printf '%s\n' 'if len(ss) > MAX or not ss.endswith("..."):'
  printf '%s\n' '    errors.append("3: overlong child summary_short not visibly truncated: len={0}".format(len(ss)))'
  printf '%s\n' ''
  printf '%s\n' '# Tooth 4: empty `summary` is STILL fatal (the hard boundary is preserved).'
  printf '%s\n' 'try:'
  printf '%s\n' '    validate_result(base(delivery_intent="main_session_only", summary_short="ok", summary="   "))'
  printf '%s\n' '    errors.append("4: empty summary should have raised ValueError")'
  printf '%s\n' 'except ValueError:'
  printf '%s\n' '    pass'
  printf '%s\n' ''
  printf '%s\n' '# Tooth 4b: SCOPE FENCE — a bad forward_target is STILL fatal (the'
  printf '%s\n' '# error-envelope substitution path is NOT generalized).'
  printf '%s\n' 'try:'
  printf '%s\n' '    validate_result(base(delivery_intent="forward_to_user", summary_short="ok", forward_target={"channel": "telegram"}))'
  printf '%s\n' '    errors.append("4b: bad forward_target should have raised ValueError")'
  printf '%s\n' 'except ValueError:'
  printf '%s\n' '    pass'
  printf '%s\n' ''
  printf '%s\n' '# Tooth 5: a valid non-empty in-bounds summary_short passes through untouched'
  printf '%s\n' '# and produces NO normalization note.'
  printf '%s\n' 'r = validate_result(base(delivery_intent="main_session_only", summary_short="Tight digest"))'
  printf '%s\n' 'if r.get("summary_short") != "Tight digest":'
  printf '%s\n' '    errors.append("5: valid short was mutated: {0!r}".format(r.get("summary_short")))'
  printf '%s\n' 'if "summary_short_normalized" in r:'
  printf '%s\n' '    errors.append("5: spurious normalization note on a clean value")'
  printf '%s\n' ''
  printf '%s\n' 'if errors:'
  printf '%s\n' '    for e in errors:'
  printf '%s\n' '        print("[smoke][error] " + e, file=sys.stderr)'
  printf '%s\n' '    sys.exit(1)'
  printf '%s\n' ''
  printf '%s\n' 'print("[smoke] cron-runner summary_short derive/truncate invariants ok")'
} >"$HELPER"

smoke_log "running summary_short derive check via $HELPER"
REPO_ROOT="$REPO_ROOT" "$PY_BIN" "$HELPER"

smoke_log "ok"
