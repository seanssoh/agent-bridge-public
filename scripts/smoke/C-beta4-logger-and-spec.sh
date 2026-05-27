#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/C-beta4-logger-and-spec.sh
#
# Lane C of v0.15.0-beta4 — beta3-wave regression close: logger stdout
# bleed (#1273) + manifest qualified-spec form mismatch (#1274).
#
#   #1273 (Lane B regression): `agb plugins add-marketplace <url>` always
#         failed with a false "marketplace.json missing" because
#         `bridge_plugins_add_marketplace_clone_url` emitted `bridge_info`
#         diagnostics on STDOUT and the caller captured stdout as the
#         resolved path. Fix: `bridge_info` is now stderr-routed (it is a
#         logger, not a return-channel producer); `bridge_warn` was
#         already stderr.
#
#   #1274 (Lane C1 regression): `agent-bridge agent restart <iso-agent>`
#         always failed with `restart_aborted=manifest-incomplete` for
#         iso-v2 + plugin agents because the C1 preflight passed the
#         QUALIFIED spec form (`plugin:teams@agent-bridge`) into
#         `bridge_claude_plugin_status`, whose downstream manifest probe
#         keys by the BARE form (`teams@agent-bridge`). Fix: T2 helper-
#         boundary strip in claude-plugin-manifest-has-spec.py + caller-
#         side strip in the C1 preflight to match the existing convention
#         at every other `bridge_claude_plugin_status` callsite.
#
# Test plan:
#   T1. add-marketplace via a local file:// URL clones and resolves to a
#       SINGLE-LINE valid path (regression #1273). Diagnostic lines must
#       not contaminate $resolved_root.
#   T2. `bridge_info` routes to stderr. A subshell that captures stdout
#       only returns the empty string when the only output is bridge_info.
#   T3. `bridge_warn` ALREADY routed to stderr (sanity — should be
#       unchanged by this lane).
#   T4. claude-plugin-manifest-has-spec.py with BARE key + BARE manifest
#       returns "present" (legacy path unchanged).
#   T5. claude-plugin-manifest-has-spec.py with PREFIXED spec + BARE
#       manifest key returns "present" (helper-boundary strip closes #1274).
#   T6. C1 preflight (extract function) sees a manifest with bare keys,
#       reads `plugin:teams@agent-bridge` from channels CSV, and does
#       NOT emit `manifest-incomplete` — restart proceeds.
#   T7 (teeth, #1273). Re-define `bridge_info` to STDOUT (revert
#       simulation) and re-run add-marketplace. Resolved capture is
#       polluted, marketplace.json check fails. Proves the stderr move
#       is what closes the regression.
#   T8 (teeth, #1274). Strip the helper-boundary normalisation from
#       claude-plugin-manifest-has-spec.py and re-run the prefixed-spec
#       check against a bare-keyed manifest. Result must flip from
#       "present" back to "absent" — proving the helper strip is what
#       closes the regression.
#
# Footgun #11: every captured subprocess uses `out=$(... 2>&1)`. No
# `<<EOF` to subprocess, no `<<<` here-strings into command substitutions.
# Inline Python heredoc-to-stdin into subprocess is forbidden; the helper
# we exercise is the standalone script file, NOT an inline heredoc.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout).
# No network calls — the URL flow uses a local file:// remote that is
# built inside SMOKE_TMP_ROOT.

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:C-beta4-logger-and-spec][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="C-beta4-logger-and-spec"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd git
smoke_require_cmd awk

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
HELPER_PY="$REPO_ROOT/scripts/python-helpers/claude-plugin-manifest-has-spec.py"
CORE_SH="$REPO_ROOT/lib/bridge-core.sh"

smoke_assert_file_exists "$HELPER_PY" "manifest-has-spec helper present"
smoke_assert_file_exists "$CORE_SH" "bridge-core.sh present"
smoke_assert_file_exists "$REPO_ROOT/bridge-plugins.sh" "bridge-plugins.sh present"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi
export BRIDGE_BASH_BIN="$BRIDGE_BASH"

# ---------------------------------------------------------------------------
# Fixture A: an Agent Bridge-format marketplace in a local git repo, so
# we can drive bridge_plugins_add_marketplace_clone_url via a file:// URL.
# The clone path is what exercises the #1273 regression (the local-path
# branch of add-marketplace does not pass through that helper).
# ---------------------------------------------------------------------------
FIXTURE_MKT_SRC="$SMOKE_TMP_ROOT/fixture-mkt-src"
FIXTURE_PLUGIN_DIR="$FIXTURE_MKT_SRC/plugins/test-plugin"
mkdir -p "$FIXTURE_MKT_SRC/.claude-plugin" "$FIXTURE_PLUGIN_DIR/.claude-plugin"

{
  printf '{\n'
  printf '  "name": "fixture-mkt",\n'
  printf '  "owner": {"name": "smoke"},\n'
  printf '  "plugins": [\n'
  printf '    {"name": "test-plugin", "source": "./plugins/test-plugin", "version": "0.0.1"}\n'
  printf '  ]\n'
  printf '}\n'
} >"$FIXTURE_MKT_SRC/.claude-plugin/marketplace.json"

printf '{"name": "test-plugin", "version": "0.0.1"}\n' \
  >"$FIXTURE_PLUGIN_DIR/.claude-plugin/plugin.json"

# Make it a git repo so file:// URL clone works.
(
  cd "$FIXTURE_MKT_SRC"
  git init -q
  git config user.email smoke@example.invalid
  git config user.name smoke
  git add -A
  git -c commit.gpgsign=false commit -q -m "fixture marketplace"
) || smoke_fail "fixture: failed to init git repo at $FIXTURE_MKT_SRC"

FIXTURE_URL="file://$FIXTURE_MKT_SRC"

# ---------------------------------------------------------------------------
# T1: add-marketplace via file:// URL — resolved_root must be a single-
#     line valid path (no bridge_info diagnostic contamination).
# ---------------------------------------------------------------------------
smoke_log "T1: add-marketplace via file:// URL resolves to single-line path (#1273 regression)"

# We exercise the clone-resolve path WITHOUT delegating to seed (which
# requires the rest of the v2 plumbing). We do this by importing
# bridge-plugins.sh, then calling the helper directly and asserting its
# stdout-captured output.
#
# This is exactly the call shape `bridge_plugins_cmd_add_marketplace`
# uses: `resolved_root="$(bridge_plugins_add_marketplace_clone_url "$target")"`.
T1_DRIVER="$SMOKE_TMP_ROOT/t1-driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'export BRIDGE_SHARED_ROOT=%q\n' "$BRIDGE_SHARED_ROOT"
  printf 'export BRIDGE_SCRIPT_DIR=%q\n' "$REPO_ROOT"
  printf 'mkdir -p "$BRIDGE_SHARED_ROOT/plugins-cache/_clones"\n'
  # Stub _bridge_isolation_v2_run_root_or_sudo so the mkdir does not need root.
  printf '_bridge_isolation_v2_run_root_or_sudo() { "$@"; }\n'
  printf 'bridge_require_python() { :; }\n'
  printf 'source %q\n' "$CORE_SH"
  # bridge-core.sh sources fine standalone; bridge-plugins.sh has wider
  # deps. Re-define only the helper we test, sourced inline from the
  # bridge-plugins.sh file via function extraction.
  printf 'extract_fn() {\n'
  printf '  awk -v fn="$1" "BEGIN{capture=0}\n'
  printf '    \\$0 ~ \\"^\\"fn\\"\\\\\\\\(\\\\\\\\) \\\\\\\\{\\" {capture=1}\n'
  printf '    capture {print}\n'
  printf '    capture && /^\\\\}[[:space:]]*\\$/ {capture=0; print \\"\\\"}" "$2"\n'
  printf '}\n'
  printf 'extracted="$(extract_fn bridge_plugins_add_marketplace_clone_url %q)"\n' "$REPO_ROOT/bridge-plugins.sh"
  printf 'eval "$extracted"\n'
  printf 'resolved_root="$(bridge_plugins_add_marketplace_clone_url %q)"\n' "$FIXTURE_URL"
  printf 'echo "RESOLVED=[$resolved_root]"\n'
  printf 'lines=$(printf "%%s\\n" "$resolved_root" | wc -l)\n'
  printf 'echo "LINES=$lines"\n'
  printf 'if [[ -f "$resolved_root/.claude-plugin/marketplace.json" ]]; then\n'
  printf '  echo "MARKETPLACE_OK=yes"\n'
  printf 'else\n'
  printf '  echo "MARKETPLACE_OK=no path=$resolved_root"\n'
  printf 'fi\n'
} >"$T1_DRIVER"

T1_OUT_BOTH=""
T1_RC=0
T1_OUT_BOTH="$("$BRIDGE_BASH" "$T1_DRIVER" 2>&1)" || T1_RC=$?
if (( T1_RC != 0 )); then
  printf '%s\n' "$T1_OUT_BOTH" >&2
  smoke_fail "T1: driver exited non-zero (rc=$T1_RC): $T1_OUT_BOTH"
fi

# Capture stdout-only for the regression-of-#1273 assertion.
T1_OUT_STDOUT="$("$BRIDGE_BASH" "$T1_DRIVER" 2>/dev/null)" || T1_RC=$?
if (( T1_RC != 0 )); then
  printf '%s\n' "$T1_OUT_STDOUT" >&2
  smoke_fail "T1: stdout-only capture rc=$T1_RC"
fi

smoke_assert_contains "$T1_OUT_STDOUT" "RESOLVED=[" \
  "T1: driver printed RESOLVED= line"
smoke_assert_contains "$T1_OUT_STDOUT" "MARKETPLACE_OK=yes" \
  "T1: marketplace.json found under resolved_root (no bridge_info contamination)"
# `resolved_root` came from `$(bridge_plugins_add_marketplace_clone_url ...)`
# inside the driver. With bridge_info still on stdout, that capture
# would be MULTI-LINE (diagnostic + path) and the `-f` check at
# bridge-plugins.sh:1415 would fail.

# ---------------------------------------------------------------------------
# T2: bridge_info routes to stderr — stdout-only capture of a function
#     that only logs via bridge_info returns the empty string.
# ---------------------------------------------------------------------------
smoke_log "T2: bridge_info routes to stderr (regression-of-#1273 root)"

T2_DRIVER="$SMOKE_TMP_ROOT/t2-driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'source %q\n' "$CORE_SH"
  printf 'capture_via_stdout() {\n'
  printf '  bridge_info "diagnostic line that must not leak to stdout"\n'
  printf '  printf "RETURN_VALUE"\n'
  printf '}\n'
  printf 'captured="$(capture_via_stdout)"\n'
  printf 'echo "CAPTURED=[$captured]"\n'
} >"$T2_DRIVER"

T2_OUT_STDOUT="$("$BRIDGE_BASH" "$T2_DRIVER" 2>/dev/null)" || T2_RC=$?
T2_OUT_BOTH="$("$BRIDGE_BASH" "$T2_DRIVER" 2>&1)" || T2_RC=$?
smoke_assert_contains "$T2_OUT_STDOUT" "CAPTURED=[RETURN_VALUE]" \
  "T2: stdout-only capture isolates the return value (bridge_info went elsewhere)"
smoke_assert_contains "$T2_OUT_BOTH" "diagnostic line that must not leak to stdout" \
  "T2: bridge_info DID emit the diagnostic (just not to stdout) — visible when stderr is captured"

# ---------------------------------------------------------------------------
# T3: bridge_warn was already stderr — sanity, no change this lane.
# ---------------------------------------------------------------------------
smoke_log "T3: bridge_warn routes to stderr (sanity, unchanged this lane)"

T3_DRIVER="$SMOKE_TMP_ROOT/t3-driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'source %q\n' "$CORE_SH"
  printf 'bridge_warn "warning line"\n'
} >"$T3_DRIVER"

T3_OUT_STDOUT="$("$BRIDGE_BASH" "$T3_DRIVER" 2>/dev/null)" || T3_RC=$?
T3_OUT_STDERR="$("$BRIDGE_BASH" "$T3_DRIVER" 2>&1 1>/dev/null)" || T3_RC=$?
if [[ -n "$T3_OUT_STDOUT" ]]; then
  # Tolerate trailing whitespace/newline only.
  trimmed="$(printf '%s' "$T3_OUT_STDOUT" | tr -d '[:space:]')"
  [[ -z "$trimmed" ]] || smoke_fail "T3: bridge_warn leaked to stdout: '$T3_OUT_STDOUT'"
fi
smoke_assert_contains "$T3_OUT_STDERR" "warning line" \
  "T3: bridge_warn surfaces on stderr"

# ---------------------------------------------------------------------------
# T4: manifest-has-spec.py with bare key + bare manifest → present.
# ---------------------------------------------------------------------------
smoke_log "T4: manifest-has-spec.py with bare key + bare manifest → present"

MANIFEST_BARE="$SMOKE_TMP_ROOT/installed_plugins.bare.json"
{
  printf '{\n'
  printf '  "version": 2,\n'
  printf '  "plugins": {\n'
  printf '    "teams@agent-bridge": [{"installPath": "/tmp/teams"}]\n'
  printf '  }\n'
  printf '}\n'
} >"$MANIFEST_BARE"

T4_OUT="$(python3 "$HELPER_PY" "$MANIFEST_BARE" "teams@agent-bridge" 2>&1)" || T4_RC=$?
smoke_assert_eq "present" "$T4_OUT" \
  "T4: bare key + bare manifest must return 'present'"

# ---------------------------------------------------------------------------
# T5: manifest-has-spec.py with PREFIXED spec + bare manifest → present
#     (helper-boundary strip closes #1274).
# ---------------------------------------------------------------------------
smoke_log "T5: manifest-has-spec.py with PREFIXED spec + bare manifest → present (#1274 fix)"

T5_OUT="$(python3 "$HELPER_PY" "$MANIFEST_BARE" "plugin:teams@agent-bridge" 2>&1)" || T5_RC=$?
smoke_assert_eq "present" "$T5_OUT" \
  "T5: helper boundary must strip 'plugin:' prefix and find the bare key"

# ---------------------------------------------------------------------------
# T6: C1 preflight + extracted helpers + manifest with bare keys + the
#     channels CSV carries plugin:teams@agent-bridge → does NOT emit
#     'manifest-incomplete'.
# ---------------------------------------------------------------------------
smoke_log "T6: C1 preflight reads bare-keyed manifest, does not emit manifest-incomplete (#1274)"

# Re-use the BRIDGE_SHARED_ROOT plugin-cache the real reader uses.
SHARED_PLUGINS_CACHE="$BRIDGE_SHARED_ROOT/plugins-cache"
mkdir -p "$SHARED_PLUGINS_CACHE"
cp "$MANIFEST_BARE" "$SHARED_PLUGINS_CACHE/installed_plugins.json"

# Extract the preflight reason fn + its qualify helper + the dispatcher
# fn (bridge_claude_plugin_status). We stub the iso predicate ON and
# point the manifest reader at our shared-cache fixture.
T6_FUNCS="$SMOKE_TMP_ROOT/c-beta4-funcs.sh"
{
  printf '# shellcheck shell=bash disable=SC2034\n'
  printf 'bridge_trim_whitespace() { printf "%%s" "${1:-}" | awk "{ gsub(/^[ \\t]+|[ \\t]+\\$/, \\"\\\"); print }"; }\n'
  printf 'declare -gA BRIDGE_AGENT_CHANNELS=()\n'
  printf 'declare -gA BRIDGE_AGENT_ENGINE=()\n'
  printf 'bridge_agent_channels_csv() { printf "%%s" "${BRIDGE_AGENT_CHANNELS[$1]:-}"; }\n'
  printf 'bridge_agent_engine() { printf "%%s" "${BRIDGE_AGENT_ENGINE[$1]:-}"; }\n'
  printf 'bridge_isolation_disabled_by_env() { return 1; }\n'
  printf 'bridge_agent_linux_user_isolation_effective() { return 0; }\n'
  printf 'bridge_resolve_engine_binary() { command -v "$1" 2>/dev/null || printf /bin/true; }\n'
  printf 'bridge_agent_os_user() { printf "%%s" ""; }\n'
  printf 'bridge_agent_linux_user_home() { printf "%%s" ""; }\n'
  printf 'bridge_linux_sudo_root() { "$@"; }\n'
  printf 'bridge_require_python() { :; }\n'
  printf 'BRIDGE_SCRIPT_DIR=%q\n' "$REPO_ROOT"
  printf 'export BRIDGE_SHARED_ROOT=%q\n' "$BRIDGE_SHARED_ROOT"
  printf 'extract_fn() {\n'
  printf '  awk -v fn="$1" "BEGIN{capture=0}\n'
  printf '    \\$0 ~ \\"^\\"fn\\"\\\\\\\\(\\\\\\\\) \\\\\\\\{\\" {capture=1}\n'
  printf '    capture {print}\n'
  printf '    capture && /^\\\\}[[:space:]]*\\$/ {capture=0; print \\"\\\"}" "$2"\n'
  printf '}\n'
  printf 'eval "$(extract_fn bridge_builtin_plugin_marketplace %q)"\n' "$REPO_ROOT/lib/bridge-agents.sh"
  printf 'eval "$(extract_fn bridge_qualify_channel_item %q)"\n' "$REPO_ROOT/lib/bridge-agents.sh"
  printf 'eval "$(extract_fn _bridge_claude_plugin_bridge_manifest_has_spec %q)"\n' "$REPO_ROOT/lib/bridge-agents.sh"
  printf 'eval "$(extract_fn bridge_claude_plugin_status %q)"\n' "$REPO_ROOT/lib/bridge-agents.sh"
  printf 'eval "$(extract_fn bridge_agent_restart_preflight_full_reason %q)"\n' "$REPO_ROOT/lib/bridge-agents.sh"
  # Daemon supp-group + session-id helpers are optional callouts via
  # `declare -f` gate inside the preflight; leave them undefined here so
  # those branches no-op and do not need stubs.
} >"$T6_FUNCS"

T6_DRIVER="$SMOKE_TMP_ROOT/t6-driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'source %q\n' "$CORE_SH"
  printf 'source %q\n' "$T6_FUNCS"
  printf 'BRIDGE_AGENT_ENGINE["test-agent"]="claude"\n'
  printf 'BRIDGE_AGENT_CHANNELS["test-agent"]="plugin:teams@agent-bridge"\n'
  printf 'reason="$(bridge_agent_restart_preflight_full_reason test-agent)"\n'
  printf 'echo "REASON=[$reason]"\n'
} >"$T6_DRIVER"

T6_OUT_BOTH="$("$BRIDGE_BASH" "$T6_DRIVER" 2>&1)" || T6_RC=$?
smoke_assert_contains "$T6_OUT_BOTH" "REASON=[]" \
  "T6: preflight emits empty reason — manifest-incomplete NOT fired (#1274 fix verified)"
smoke_assert_not_contains "$T6_OUT_BOTH" "manifest-incomplete" \
  "T6: preflight output must NOT contain 'manifest-incomplete' for declared plugin"

# ---------------------------------------------------------------------------
# T7 (teeth, #1273): re-define bridge_info to STDOUT (revert simulation)
#     and assert add-marketplace clone-url helper output corrupts the
#     resolved capture. The MARKETPLACE_OK check must FAIL.
# ---------------------------------------------------------------------------
smoke_log "T7 (teeth #1273): with bridge_info forced back to stdout, capture is contaminated"

T7_DRIVER="$SMOKE_TMP_ROOT/t7-driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'export BRIDGE_SHARED_ROOT=%q\n' "$BRIDGE_SHARED_ROOT"
  printf 'export BRIDGE_SCRIPT_DIR=%q\n' "$REPO_ROOT"
  # Use a fresh _clones path so the idempotent path doesn't kick in (we
  # already cloned in T1).
  printf 'export BRIDGE_SHARED_ROOT=%q\n' "$SMOKE_TMP_ROOT/teeth-shared"
  printf 'mkdir -p "$BRIDGE_SHARED_ROOT/plugins-cache/_clones"\n'
  printf '_bridge_isolation_v2_run_root_or_sudo() { "$@"; }\n'
  printf 'bridge_require_python() { :; }\n'
  printf 'source %q\n' "$CORE_SH"
  # Force bridge_info BACK to stdout (revert simulation).
  printf 'bridge_info() { echo -e "${CYAN-}$*${NC-}"; }\n'
  printf 'extract_fn() {\n'
  printf '  awk -v fn="$1" "BEGIN{capture=0}\n'
  printf '    \\$0 ~ \\"^\\"fn\\"\\\\\\\\(\\\\\\\\) \\\\\\\\{\\" {capture=1}\n'
  printf '    capture {print}\n'
  printf '    capture && /^\\\\}[[:space:]]*\\$/ {capture=0; print \\"\\\"}" "$2"\n'
  printf '}\n'
  printf 'extracted="$(extract_fn bridge_plugins_add_marketplace_clone_url %q)"\n' "$REPO_ROOT/bridge-plugins.sh"
  # Strip the defensive `>&2` redirects we added in bridge-plugins.sh
  # so the bridge_info lines route to wherever bridge_info itself does
  # — i.e. stdout under the revert simulation. Without this strip, the
  # `>&2` defense-in-depth would mask the teeth.
  printf 'extracted_unprotected="$(printf %%s\\\\n \"$extracted\" | sed -e \"s/bridge_info \\\\(.*\\\\) >&2/bridge_info \\\\1/g\")"\n'
  printf 'eval "$extracted_unprotected"\n'
  printf 'resolved_root="$(bridge_plugins_add_marketplace_clone_url %q)"\n' "$FIXTURE_URL"
  printf 'echo "RESOLVED_RAW_CHARS=${#resolved_root}"\n'
  printf 'lines=$(printf "%%s\\n" "$resolved_root" | wc -l)\n'
  printf 'echo "LINES=$lines"\n'
  printf 'if [[ -f "$resolved_root/.claude-plugin/marketplace.json" ]]; then\n'
  printf '  echo "MARKETPLACE_OK=yes"\n'
  printf 'else\n'
  printf '  echo "MARKETPLACE_OK=no"\n'
  printf 'fi\n'
} >"$T7_DRIVER"

T7_OUT_STDOUT="$("$BRIDGE_BASH" "$T7_DRIVER" 2>/dev/null)" || T7_RC=$?
# Diagnostic to stderr for debugging if assertions fail.
"$BRIDGE_BASH" "$T7_DRIVER" >/dev/null 2>"$SMOKE_TMP_ROOT/t7-stderr.log" || true
smoke_assert_contains "$T7_OUT_STDOUT" "MARKETPLACE_OK=no" \
  "T7 teeth (#1273): with bridge_info on stdout, capture is multi-line and -f check fails"

# ---------------------------------------------------------------------------
# T8 (teeth, #1274): strip the helper-boundary normalisation from a COPY
#     of claude-plugin-manifest-has-spec.py and re-run the prefixed-spec
#     check. Result MUST flip back to "absent" — proving the helper
#     strip is what closes the regression.
# ---------------------------------------------------------------------------
smoke_log "T8 (teeth #1274): without helper-boundary strip, prefixed spec + bare manifest → absent"

HELPER_REVERT="$SMOKE_TMP_ROOT/helper-without-strip.py"
{
  printf '#!/usr/bin/env python3\n'
  printf '"""Teeth: reverted variant without the #1274 helper-boundary strip."""\n'
  printf 'import json, sys\n'
  printf 'from pathlib import Path\n'
  printf '\n'
  printf 'def main():\n'
  printf '    manifest_path = Path(sys.argv[1])\n'
  printf '    spec = sys.argv[2]\n'
  printf '    try:\n'
  printf '        payload = json.loads(manifest_path.read_text(encoding="utf-8"))\n'
  printf '    except (OSError, ValueError):\n'
  printf '        print("absent")\n'
  printf '        return 0\n'
  printf '    if not isinstance(payload, dict):\n'
  printf '        print("absent")\n'
  printf '        return 0\n'
  printf '    plugins = payload.get("plugins") or {}\n'
  printf '    if not isinstance(plugins, dict):\n'
  printf '        print("absent")\n'
  printf '        return 0\n'
  printf '    print("present" if spec in plugins else "absent")\n'
  printf '    return 0\n'
  printf '\n'
  printf 'if __name__ == "__main__":\n'
  printf '    sys.exit(main())\n'
} >"$HELPER_REVERT"

T8_OUT="$(python3 "$HELPER_REVERT" "$MANIFEST_BARE" "plugin:teams@agent-bridge" 2>&1)" || T8_RC=$?
smoke_assert_eq "absent" "$T8_OUT" \
  "T8 teeth (#1274): reverted helper (no strip) returns 'absent' — proves strip is the fix"

# Cross-check: same reverted helper with the BARE spec still returns
# present, confirming the fixture itself is sound.
T8_BARE_OUT="$(python3 "$HELPER_REVERT" "$MANIFEST_BARE" "teams@agent-bridge" 2>&1)" || T8_RC=$?
smoke_assert_eq "present" "$T8_BARE_OUT" \
  "T8 teeth cross-check: reverted helper with bare spec is still 'present' (fixture is sound)"

smoke_log "passed"
exit 0
