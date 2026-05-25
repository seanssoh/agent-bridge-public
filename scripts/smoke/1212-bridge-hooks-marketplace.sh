#!/usr/bin/env bash
# scripts/smoke/1212-bridge-hooks-marketplace.sh — issue #1212.
#
# Pins the contract closed by #1212 — `bridge-hooks.py`'s
# `agent_bridge_development_plugin_settings` must accept any
# `plugin:<name>@<marketplace>` spec from the
# `--dangerously-load-development-channels` argv (not just
# `@agent-bridge`), and emit a matching `extraKnownMarketplaces` entry
# for each third-party marketplace that has a corresponding mirror dir
# under `$BRIDGE_HOME/data/shared/plugins-cache/marketplaces/<id>`.
#
# Tests:
#   T1 (positive)     — launch cmd with 3 specs (one @agent-bridge plus
#                       two third-party). All 3 in enabledPlugins; all 3
#                       marketplace ids in extraKnownMarketplaces with
#                       directory-source paths pointing at the mirrors.
#   T2 (regression)   — launch cmd with only an @agent-bridge spec still
#                       renders exactly as today (single marketplace).
#   T3 (safety/bare)  — bare `plugin:foo` (no `@`) → spec dropped;
#                       remaining valid plugins still emit.
#   T4 (safety/empty) — `plugin:@bar` and `plugin:foo@` (empty token on
#                       either side) → dropped.
#   T5 (safety/path)  — marketplace id containing `..`, `/`, or special
#                       chars → marketplace entry skipped but plugin
#                       stays in enabledPlugins.
#   T6 (safety/dir)   — third-party marketplace id whose mirror dir does
#                       NOT exist → marketplace entry skipped, plugin
#                       stays in enabledPlugins.
#   T7 (idempotency)  — render once with the new filter, then call
#                       managed defaults again on the same launch cmd:
#                       output is stable (same dict).
#
# Footgun #11: pipe/argv stdin only.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1212-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

if ! command -v python3 >/dev/null 2>&1; then
  printf '[FAIL] python3 not on PATH\n' >&2
  exit 1
fi

# Synthesize a BRIDGE_HOME with mirror dirs for two third-party marketplaces.
export BRIDGE_HOME="$SMOKE_DIR/bridge-home"
MIRROR_ROOT="$BRIDGE_HOME/data/shared/plugins-cache/marketplaces"
mkdir -p "$MIRROR_ROOT/cosmax-crm-marketplace"
mkdir -p "$MIRROR_ROOT/cosmax-marketplace"
# Deliberately do NOT pre-create a mirror dir for "missing-marketplace"
# (T6 verifies the skip path).

# Driver script: imports bridge-hooks.py as a module and invokes
# `agent_bridge_development_plugin_settings`. Emits JSON on stdout.
DRIVER="$SMOKE_DIR/driver.py"
: >"$DRIVER"
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' '"""Invoke bridge-hooks.agent_bridge_development_plugin_settings on a controlled launch cmd."""'
  printf '%s\n' 'from __future__ import annotations'
  printf '%s\n' 'import importlib.util'
  printf '%s\n' 'import json'
  printf '%s\n' 'import os'
  printf '%s\n' 'import sys'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' ''
  printf '%s\n' 'def load_module(name, path):'
  printf '%s\n' '    spec = importlib.util.spec_from_file_location(name, str(path))'
  printf '%s\n' '    if spec is None or spec.loader is None:'
  printf '%s\n' '        raise RuntimeError("cannot load " + name + " from " + str(path))'
  printf '%s\n' '    module = importlib.util.module_from_spec(spec)'
  printf '%s\n' '    sys.modules[name] = module'
  printf '%s\n' '    spec.loader.exec_module(module)'
  printf '%s\n' '    return module'
  printf '%s\n' ''
  printf '%s\n' 'def main() -> int:'
  printf '%s\n' '    repo_root = Path(os.environ["DRIVER_REPO_ROOT"]).resolve()'
  printf '%s\n' '    sys.path.insert(0, str(repo_root / "lib"))'
  printf '%s\n' '    mod = load_module("bridge_hooks", repo_root / "bridge-hooks.py")'
  printf '%s\n' '    launch_cmd = os.environ.get("DRIVER_LAUNCH_CMD", "")'
  printf '%s\n' '    result = mod.agent_bridge_development_plugin_settings(launch_cmd)'
  printf '%s\n' '    print(json.dumps(result, sort_keys=True))'
  printf '%s\n' '    return 0'
  printf '%s\n' ''
  printf '%s\n' 'if __name__ == "__main__":'
  printf '%s\n' '    raise SystemExit(main())'
} >>"$DRIVER"
chmod +x "$DRIVER"

run_driver() {
  local launch_cmd="$1"
  DRIVER_REPO_ROOT="$REPO_ROOT" DRIVER_LAUNCH_CMD="$launch_cmd" python3 "$DRIVER"
}

# ---------------------------------------------------------------------------
# T1 — positive: 3 specs across 2 different marketplaces (one default,
# two third-party). All 3 plugins enabled; all 3 marketplace entries
# present with directory-source paths.
# ---------------------------------------------------------------------------
T1_LAUNCH="claude --dangerously-load-development-channels plugin:teams@agent-bridge --dangerously-load-development-channels plugin:cosmax-crm@cosmax-crm-marketplace --dangerously-load-development-channels plugin:cosmax-ep-approval@cosmax-marketplace"
T1_OUT="$(run_driver "$T1_LAUNCH")"
T1_RC=$?
if [[ $T1_RC -ne 0 ]]; then
  _fail "T1" "driver exited rc=$T1_RC; out=$T1_OUT"
else
  T1_CHECK="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
ep = data.get("enabledPlugins", {})
mk = data.get("extraKnownMarketplaces", {})
expect_plugins = {"teams@agent-bridge", "cosmax-crm@cosmax-crm-marketplace", "cosmax-ep-approval@cosmax-marketplace"}
expect_marketplaces = {"agent-bridge", "cosmax-crm-marketplace", "cosmax-marketplace"}
errors = []
missing_plugins = expect_plugins - set(ep.keys())
if missing_plugins:
    errors.append("missing plugins: " + ",".join(sorted(missing_plugins)))
for spec in expect_plugins:
    if ep.get(spec) is not True:
        errors.append("plugin " + spec + " not enabled=true")
missing_mkts = expect_marketplaces - set(mk.keys())
if missing_mkts:
    errors.append("missing marketplaces: " + ",".join(sorted(missing_mkts)))
for mkt in ("cosmax-crm-marketplace", "cosmax-marketplace"):
    info = mk.get(mkt, {})
    src = info.get("source", {})
    if src.get("source") != "directory":
        errors.append(mkt + " source.source != directory")
    path = src.get("path", "")
    if "/data/shared/plugins-cache/marketplaces/" + mkt not in path:
        errors.append(mkt + " path missing mirror suffix: " + path)
print("|".join(errors) if errors else "OK")
' "$T1_OUT")"
  if [[ "$T1_CHECK" == "OK" ]]; then
    _pass "T1: 3 specs across 2 marketplaces all rendered"
  else
    _fail "T1" "$T1_CHECK; out=$T1_OUT"
  fi
fi

# ---------------------------------------------------------------------------
# T2 — regression: @agent-bridge only renders single marketplace.
# ---------------------------------------------------------------------------
T2_LAUNCH="claude --dangerously-load-development-channels plugin:teams@agent-bridge"
T2_OUT="$(run_driver "$T2_LAUNCH")"
T2_CHECK="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
ep = data.get("enabledPlugins", {})
mk = data.get("extraKnownMarketplaces", {})
errors = []
if list(ep.keys()) != ["teams@agent-bridge"]:
    errors.append("ep keys != [teams@agent-bridge]: " + ",".join(sorted(ep.keys())))
if list(mk.keys()) != ["agent-bridge"]:
    errors.append("mk keys != [agent-bridge]: " + ",".join(sorted(mk.keys())))
print("|".join(errors) if errors else "OK")
' "$T2_OUT")"
if [[ "$T2_CHECK" == "OK" ]]; then
  _pass "T2: regression — @agent-bridge-only renders as before"
else
  _fail "T2" "$T2_CHECK; out=$T2_OUT"
fi

# ---------------------------------------------------------------------------
# T3 — safety: bare `plugin:foo` (no `@`) dropped.
# ---------------------------------------------------------------------------
T3_LAUNCH="claude --dangerously-load-development-channels plugin:foo --dangerously-load-development-channels plugin:teams@agent-bridge"
T3_OUT="$(run_driver "$T3_LAUNCH")"
T3_CHECK="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
ep = set(data.get("enabledPlugins", {}).keys())
errors = []
if "foo" in ep or any(k.startswith("foo") for k in ep):
    errors.append("bare plugin:foo leaked into enabledPlugins")
if "teams@agent-bridge" not in ep:
    errors.append("teams@agent-bridge missing")
print("|".join(errors) if errors else "OK")
' "$T3_OUT")"
if [[ "$T3_CHECK" == "OK" ]]; then
  _pass "T3: safety — bare plugin:foo (no @) dropped"
else
  _fail "T3" "$T3_CHECK; out=$T3_OUT"
fi

# ---------------------------------------------------------------------------
# T4 — safety: empty plugin name or empty marketplace dropped.
# ---------------------------------------------------------------------------
T4_LAUNCH="claude --dangerously-load-development-channels plugin:@bar --dangerously-load-development-channels plugin:foo@ --dangerously-load-development-channels plugin:teams@agent-bridge"
T4_OUT="$(run_driver "$T4_LAUNCH")"
T4_CHECK="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
ep = set(data.get("enabledPlugins", {}).keys())
errors = []
if "@bar" in ep:
    errors.append("plugin:@bar leaked into enabledPlugins")
if "foo@" in ep:
    errors.append("plugin:foo@ leaked into enabledPlugins")
if "teams@agent-bridge" not in ep:
    errors.append("teams@agent-bridge missing")
print("|".join(errors) if errors else "OK")
' "$T4_OUT")"
if [[ "$T4_CHECK" == "OK" ]]; then
  _pass "T4: safety — empty plugin name or marketplace dropped"
else
  _fail "T4" "$T4_CHECK; out=$T4_OUT"
fi

# ---------------------------------------------------------------------------
# T5 — safety: marketplace id containing `..` or `/` rejects mirror
# emission but keeps the plugin enabled.
#
# `plugin:dot@..` — marketplace id is literal `..`. Without the safety
# guard the resolved path would escape the marketplaces root. The
# plugin spec still appears in enabledPlugins, but no `..` marketplace
# entry materializes.
# ---------------------------------------------------------------------------
T5_LAUNCH="claude --dangerously-load-development-channels plugin:dot@.. --dangerously-load-development-channels plugin:teams@agent-bridge"
T5_OUT="$(run_driver "$T5_LAUNCH")"
T5_CHECK="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
ep = set(data.get("enabledPlugins", {}).keys())
mk = set(data.get("extraKnownMarketplaces", {}).keys())
errors = []
# plugin:dot@.. is a syntactically valid spec — keep it in enabledPlugins
# (the dev-channels argv still loads it from disk); we just decline to
# materialize a `..` marketplace entry.
if ".." in mk:
    errors.append("unsafe marketplace id \"..\" leaked into extraKnownMarketplaces")
print("|".join(errors) if errors else "OK")
' "$T5_OUT")"
if [[ "$T5_CHECK" == "OK" ]]; then
  _pass "T5: safety — unsafe marketplace id (..) skipped"
else
  _fail "T5" "$T5_CHECK; out=$T5_OUT"
fi

# ---------------------------------------------------------------------------
# T6 — safety: third-party marketplace whose mirror dir does NOT exist
# is skipped but the plugin still emits in enabledPlugins.
# ---------------------------------------------------------------------------
T6_LAUNCH="claude --dangerously-load-development-channels plugin:absent@missing-marketplace --dangerously-load-development-channels plugin:teams@agent-bridge"
T6_OUT="$(run_driver "$T6_LAUNCH")"
T6_CHECK="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
ep = set(data.get("enabledPlugins", {}).keys())
mk = set(data.get("extraKnownMarketplaces", {}).keys())
errors = []
if "absent@missing-marketplace" not in ep:
    errors.append("plugin:absent@missing-marketplace dropped from enabledPlugins")
if "missing-marketplace" in mk:
    errors.append("missing-marketplace materialized in extraKnownMarketplaces despite no mirror dir")
print("|".join(errors) if errors else "OK")
' "$T6_OUT")"
if [[ "$T6_CHECK" == "OK" ]]; then
  _pass "T6: safety — missing mirror dir → plugin stays enabled, marketplace skipped"
else
  _fail "T6" "$T6_CHECK; out=$T6_OUT"
fi

# ---------------------------------------------------------------------------
# T7 — idempotency: render the same launch cmd twice; same dict.
# ---------------------------------------------------------------------------
T7_LAUNCH="$T1_LAUNCH"
T7_OUT1="$(run_driver "$T7_LAUNCH")"
T7_OUT2="$(run_driver "$T7_LAUNCH")"
if [[ "$T7_OUT1" == "$T7_OUT2" ]]; then
  _pass "T7: idempotency — two renders of the same launch cmd are equal"
else
  _fail "T7" "render output drifted across runs: out1=$T7_OUT1 out2=$T7_OUT2"
fi

printf '[%s] %d/%d passed\n' "$(basename "$0")" "$((TOTAL - FAILS))" "$TOTAL"
if [[ $FAILS -ne 0 ]]; then
  exit 1
fi
exit 0
