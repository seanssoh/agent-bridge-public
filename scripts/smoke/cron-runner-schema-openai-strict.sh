#!/usr/bin/env bash
# scripts/smoke/cron-runner-schema-openai-strict.sh — v0.13.5 hotfix smoke.
#
# Regression guard for the OpenAI Responses API "Structured Outputs strict
# mode" contract that bridge-cron-runner.py's RESULT_SCHEMA must obey when
# the codex engine handles a `payload_kind=text` cron job. Strict mode
# requires that every key in every nested `properties` block also appear
# in that block's `required` array, and that `additionalProperties: false`
# is set on every object node.
#
# Before this PR, RESULT_SCHEMA had two violations:
#   1. Top-level `required` listed 9 of 12 properties (omitted
#      `forward_target`, `summary_short`, `channel_relay`).
#   2. `channel_relay.required` listed only `["body"]` while
#      `channel_relay.properties` had 5 keys (body, urgency, transport,
#      target, subject).
#
# The live picker-sweep cron failed every 10 minutes against the upstream
# Responses API with the verbatim error:
#   'required' is required to be supplied and to be an array including
#   every key in properties. Missing 'urgency'.
#
# The fix is schema-only (the runtime validator + normalizers are already
# null-safe). This smoke fails the build if any future PR re-introduces
# either violation.
#
# Footgun #11 (Bash 5.3.9 heredoc deadlock): this smoke writes its inline
# Python helper via `printf` to a tmp file and runs `python3 <file>` — no
# heredoc, no here-string.

set -euo pipefail

SMOKE_NAME="cron-runner-schema-openai-strict"
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

HELPER="$SMOKE_TMP_ROOT/schema_invariant_check.py"

# Build the helper line-by-line via printf — no heredoc / no here-string.
{
  printf '%s\n' 'import importlib.util, json, os, sys'
  printf '%s\n' ''
  printf '%s\n' 'repo_root = os.environ["REPO_ROOT"]'
  printf '%s\n' 'target = os.path.join(repo_root, "bridge-cron-runner.py")'
  printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_cron_runner", target)'
  printf '%s\n' 'module = importlib.util.module_from_spec(spec)'
  printf '%s\n' 'spec.loader.exec_module(module)'
  printf '%s\n' 'schema = module.RESULT_SCHEMA'
  printf '%s\n' ''
  printf '%s\n' 'errors = []'
  printf '%s\n' ''
  printf '%s\n' 'def walk(node, path):'
  printf '%s\n' '    if not isinstance(node, dict):'
  printf '%s\n' '        return'
  printf '%s\n' '    if node.get("type") == "object":'
  printf '%s\n' '        props = node.get("properties", {}) or {}'
  printf '%s\n' '        req = set(node.get("required", []) or [])'
  printf '%s\n' '        prop_keys = set(props.keys())'
  printf '%s\n' '        missing = sorted(prop_keys - req)'
  printf '%s\n' '        if missing:'
  printf '%s\n' '            errors.append("required missing at {0}: {1}".format(path, missing))'
  printf '%s\n' '        if node.get("additionalProperties", True) is not False:'
  printf '%s\n' '            errors.append("additionalProperties != False at {0}".format(path))'
  printf '%s\n' '        for k, v in props.items():'
  printf '%s\n' '            walk(v, "{0}.{1}".format(path, k))'
  printf '%s\n' '    for k, v in node.items():'
  printf '%s\n' '        if k in ("anyOf", "allOf", "oneOf"):'
  printf '%s\n' '            for i, item in enumerate(v):'
  printf '%s\n' '                walk(item, "{0}.{1}[{2}]".format(path, k, i))'
  printf '%s\n' ''
  printf '%s\n' 'walk(schema, "$")'
  printf '%s\n' ''
  printf '%s\n' 'top_required = set(schema.get("required", []) or [])'
  printf '%s\n' 'top_props = set((schema.get("properties", {}) or {}).keys())'
  printf '%s\n' 'expected_required = {'
  printf '%s\n' '    "status", "summary", "findings", "actions_taken",'
  printf '%s\n' '    "needs_human_followup", "recommended_next_steps",'
  printf '%s\n' '    "artifacts", "confidence", "delivery_intent",'
  printf '%s\n' '    "forward_target", "summary_short", "channel_relay",'
  printf '%s\n' '}'
  printf '%s\n' 'if top_required != expected_required:'
  printf '%s\n' '    errors.append("top-level required != expected; got {0}".format(sorted(top_required)))'
  printf '%s\n' 'if top_props != expected_required:'
  printf '%s\n' '    errors.append("top-level properties != expected; got {0}".format(sorted(top_props)))'
  printf '%s\n' ''
  printf '%s\n' '# channel_relay must require all 5 keys (the verbatim operator-host failure).'
  printf '%s\n' 'cr_node = schema["properties"]["channel_relay"]'
  printf '%s\n' 'cr_branches = cr_node.get("anyOf") or [cr_node]'
  printf '%s\n' 'cr_object = next((b for b in cr_branches if b.get("type") == "object"), None)'
  printf '%s\n' 'if cr_object is None:'
  printf '%s\n' '    errors.append("channel_relay anyOf has no object branch")'
  printf '%s\n' 'else:'
  printf '%s\n' '    cr_required = set(cr_object.get("required", []) or [])'
  printf '%s\n' '    cr_expected = {"body", "urgency", "transport", "target", "subject"}'
  printf '%s\n' '    if cr_required != cr_expected:'
  printf '%s\n' '        errors.append("channel_relay.required != expected; got {0}".format(sorted(cr_required)))'
  printf '%s\n' ''
  printf '%s\n' '# forward_target must require channel/target_ref/format.'
  printf '%s\n' 'ft_node = schema["properties"]["forward_target"]'
  printf '%s\n' 'ft_branches = ft_node.get("anyOf") or [ft_node]'
  printf '%s\n' 'ft_object = next((b for b in ft_branches if b.get("type") == "object"), None)'
  printf '%s\n' 'if ft_object is None:'
  printf '%s\n' '    errors.append("forward_target anyOf has no object branch")'
  printf '%s\n' 'else:'
  printf '%s\n' '    ft_required = set(ft_object.get("required", []) or [])'
  printf '%s\n' '    ft_expected = {"channel", "target_ref", "format"}'
  printf '%s\n' '    if ft_required != ft_expected:'
  printf '%s\n' '        errors.append("forward_target.required != expected; got {0}".format(sorted(ft_required)))'
  printf '%s\n' ''
  printf '%s\n' '# Each conditional top-level field must allow null via anyOf so codex can'
  printf '%s\n' '# emit null without violating strict mode. Without this, the strict-required'
  printf '%s\n' '# top-level array would force every cron payload to carry a non-null object.'
  printf '%s\n' 'for field in ("forward_target", "summary_short", "channel_relay"):'
  printf '%s\n' '    node = schema["properties"][field]'
  printf '%s\n' '    branches = node.get("anyOf")'
  printf '%s\n' '    if not branches:'
  printf '%s\n' '        errors.append("{0} missing anyOf; cannot emit null".format(field))'
  printf '%s\n' '        continue'
  printf '%s\n' '    has_null = any(b.get("type") == "null" for b in branches)'
  printf '%s\n' '    if not has_null:'
  printf '%s\n' '        errors.append("{0} anyOf has no null branch".format(field))'
  printf '%s\n' ''
  printf '%s\n' '# Confirm schema is structurally valid JSON Schema. Prefer jsonschema if'
  printf '%s\n' '# available; fall back to a json.dumps round-trip as a baseline sanity check.'
  printf '%s\n' 'try:'
  printf '%s\n' '    import jsonschema'
  printf '%s\n' '    jsonschema.Draft202012Validator.check_schema(schema)'
  printf '%s\n' '    print("[smoke] jsonschema.Draft202012Validator.check_schema ok")'
  printf '%s\n' 'except ImportError:'
  printf '%s\n' '    json.dumps(schema)'
  printf '%s\n' '    print("[smoke] jsonschema not installed; json.dumps round-trip ok")'
  printf '%s\n' ''
  printf '%s\n' 'if errors:'
  printf '%s\n' '    for e in errors:'
  printf '%s\n' '        print("[smoke][error] " + e, file=sys.stderr)'
  printf '%s\n' '    sys.exit(1)'
  printf '%s\n' ''
  printf '%s\n' 'print("[smoke] RESULT_SCHEMA OpenAI strict-mode invariants ok")'
} >"$HELPER"

smoke_log "running schema invariant check via $HELPER"
REPO_ROOT="$REPO_ROOT" "$PY_BIN" "$HELPER"

smoke_log "ok"
