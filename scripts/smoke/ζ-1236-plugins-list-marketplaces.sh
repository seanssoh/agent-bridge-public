#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/ζ-1236-plugins-list-marketplaces.sh — Issue #1236.
#
# Lane ζ smoke for the read-only plugins enumeration verbs added in
# v0.15.0-beta2:
#
#   - `agb plugins list [--json]`         — installed plugins
#   - `agb plugins marketplaces [--json]` — known marketplaces
#
# Both verbs:
#   * Return exit 0 on an empty catalog and emit an empty list.
#   * Return exit 0 on a populated catalog and enumerate every entry.
#   * Honor `--json` for machine-readable output (parseable as JSON).
#   * Honor `-h|--help` (registered in 1117 universal gate alongside).
#
# `show` semantics are unchanged — the existing 1117 + 1201/1202 smokes
# continue to pin that surface.
#
# Footgun #11: every captured subprocess uses `out=$(... 2>&1)`. No
# `<<EOF` to subprocess, no `<<<` here-strings.

# Re-exec under bash 4+ so the bridge-lib associative-array helpers work
# (the smoke does not source bridge-lib directly, but `agb plugins` does
# transitively).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:ζ-1236-plugins-list-marketplaces][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="ζ-1236-plugins-list-marketplaces"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGB_FILE="$REPO_ROOT/agent-bridge"
PLUGINS_CACHE="$BRIDGE_SHARED_ROOT/plugins-cache"
INSTALLED_MANIFEST="$PLUGINS_CACHE/installed_plugins.json"
KNOWN_MANIFEST="$PLUGINS_CACHE/known_marketplaces.json"

smoke_assert_file_exists "$AGB_FILE" "agent-bridge dispatcher present"

# Helper: run `agb plugins <verb> [args...]`, capture combined output,
# assert rc==0, and echo the captured output to caller.
run_plugins_verb() {
  local label="$1"; shift
  local out rc=0
  out="$("$AGB_FILE" plugins "$@" 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    smoke_fail "$label: rc=$rc; output: $out"
  fi
  printf '%s' "$out"
}

# Helper: assert a string is valid JSON (python3-json round-trip).
assert_valid_json() {
  local label="$1"
  local payload="$2"
  local tmp
  tmp="$(mktemp)" || smoke_fail "$label: mktemp failed"
  printf '%s' "$payload" >"$tmp"
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$tmp" \
        >/dev/null 2>&1; then
    rm -f "$tmp"
    smoke_fail "$label: payload is not valid JSON; raw: $payload"
  fi
  rm -f "$tmp"
}

# Helper: query a top-level integer field from a JSON string. Echoes the
# value or "MISSING" if the field is absent.
json_int_field() {
  local payload="$1"
  local field="$2"
  local tmp value
  tmp="$(mktemp)"
  printf '%s' "$payload" >"$tmp"
  value="$(python3 -c "
import json, sys
with open(sys.argv[1]) as h:
    data = json.load(h)
v = data.get(sys.argv[2])
if v is None:
    print('MISSING')
else:
    print(v)
" "$tmp" "$field" 2>/dev/null || printf 'MISSING')"
  rm -f "$tmp"
  printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# T1: empty catalog — both verbs return exit 0 with empty lists.
# ---------------------------------------------------------------------------
smoke_log "T1: empty catalog — list + marketplaces emit empty lists with rc=0"

# Pre-condition: smoke_setup_bridge_home does NOT seed the v2 plugins
# cache, so neither manifest exists yet.
[[ ! -f "$INSTALLED_MANIFEST" ]] \
  || smoke_fail "T1: pre-condition violated — installed_plugins.json already exists"
[[ ! -f "$KNOWN_MANIFEST" ]] \
  || smoke_fail "T1: pre-condition violated — known_marketplaces.json already exists"

OUT_LIST_EMPTY="$(run_plugins_verb "T1 list --json (empty)" list --json)"
assert_valid_json "T1 list --json parseable on empty" "$OUT_LIST_EMPTY"
count="$(json_int_field "$OUT_LIST_EMPTY" plugin_count)"
smoke_assert_eq "0" "$count" "T1 plugin_count==0 on empty catalog"

OUT_MKT_EMPTY="$(run_plugins_verb "T1 marketplaces --json (empty)" marketplaces --json)"
assert_valid_json "T1 marketplaces --json parseable on empty" "$OUT_MKT_EMPTY"
count="$(json_int_field "$OUT_MKT_EMPTY" marketplace_count)"
smoke_assert_eq "0" "$count" "T1 marketplace_count==0 on empty catalog"

# Human-readable mode on empty catalog — must also succeed.
OUT_LIST_TEXT_EMPTY="$(run_plugins_verb "T1 list (text/empty)" list)"
smoke_assert_contains "$OUT_LIST_TEXT_EMPTY" "plugin_count: 0" \
  "T1 list text mode reports plugin_count: 0 on empty"

OUT_MKT_TEXT_EMPTY="$(run_plugins_verb "T1 marketplaces (text/empty)" marketplaces)"
smoke_assert_contains "$OUT_MKT_TEXT_EMPTY" "marketplace_count: 0" \
  "T1 marketplaces text mode reports marketplace_count: 0 on empty"

# ---------------------------------------------------------------------------
# T2: populated catalog — both verbs enumerate every entry.
# ---------------------------------------------------------------------------
smoke_log "T2: populated catalog — list + marketplaces enumerate seeded entries"

# Synthesize a populated catalog by writing both manifests directly.
# This avoids requiring rsync / the bundled marketplace inside the
# smoke; the verbs are pure readers so the fixture shape is what
# matters, not the seeder path (already covered by 1201/1202).
#
# Manifests are written via printf to file (NOT heredoc-to-subprocess
# per footgun #11). The content is plain JSON literal so a single printf
# is fine.
mkdir -p "$PLUGINS_CACHE"
printf '%s\n' '{
  "version": 2,
  "plugins": {
    "teams@agent-bridge": [
      {
        "scope": "user",
        "installPath": "/fake/cache/teams@agent-bridge",
        "version": "0.1.0",
        "installedAt": "2026-05-25T00:00:00Z",
        "lastUpdated": "2026-05-25T00:00:00Z"
      }
    ],
    "ms365@agent-bridge": [
      {
        "scope": "user",
        "installPath": "/fake/cache/ms365@agent-bridge",
        "version": "0.2.0",
        "installedAt": "2026-05-25T00:00:00Z",
        "lastUpdated": "2026-05-25T00:00:00Z"
      }
    ]
  }
}' >"$INSTALLED_MANIFEST"

printf '%s\n' '{
  "agent-bridge": {
    "source": {"source": "directory", "path": "/fake/root/agent-bridge"},
    "installLocation": "/fake/root/agent-bridge",
    "lastUpdated": "2026-05-25T00:00:00Z"
  },
  "smoke-mkt": {
    "source": {"source": "directory", "path": "/tmp/smoke-mkt"},
    "installLocation": "/tmp/smoke-mkt",
    "lastUpdated": "2026-05-25T00:00:00Z"
  }
}' >"$KNOWN_MANIFEST"

OUT_LIST_POP="$(run_plugins_verb "T2 list --json (populated)" list --json)"
assert_valid_json "T2 list --json parseable when populated" "$OUT_LIST_POP"
count="$(json_int_field "$OUT_LIST_POP" plugin_count)"
smoke_assert_eq "2" "$count" "T2 plugin_count==2 with two seeded plugins"

# Spot-check that both specs survive the round-trip.
OUT_TMP="$(mktemp)"
printf '%s' "$OUT_LIST_POP" >"$OUT_TMP"
SPECS="$(python3 -c "
import json, sys
with open(sys.argv[1]) as h:
    d = json.load(h)
print(','.join(sorted(p['spec'] for p in d.get('plugins', []))))
" "$OUT_TMP")"
rm -f "$OUT_TMP"
smoke_assert_eq "ms365@agent-bridge,teams@agent-bridge" "$SPECS" \
  "T2 list emits both seeded plugin specs"

OUT_MKT_POP="$(run_plugins_verb "T2 marketplaces --json (populated)" marketplaces --json)"
assert_valid_json "T2 marketplaces --json parseable when populated" "$OUT_MKT_POP"
count="$(json_int_field "$OUT_MKT_POP" marketplace_count)"
smoke_assert_eq "2" "$count" "T2 marketplace_count==2"

OUT_TMP="$(mktemp)"
printf '%s' "$OUT_MKT_POP" >"$OUT_TMP"
IDS="$(python3 -c "
import json, sys
with open(sys.argv[1]) as h:
    d = json.load(h)
print(','.join(sorted(m['id'] for m in d.get('marketplaces', []))))
" "$OUT_TMP")"
KINDS="$(python3 -c "
import json, sys
with open(sys.argv[1]) as h:
    d = json.load(h)
print(','.join(sorted(set((m.get('source') or {}).get('kind', '') for m in d.get('marketplaces', [])))))
" "$OUT_TMP")"
rm -f "$OUT_TMP"
smoke_assert_eq "agent-bridge,smoke-mkt" "$IDS" \
  "T2 marketplaces emits both seeded marketplace ids"
smoke_assert_eq "directory" "$KINDS" \
  "T2 marketplaces source.kind round-trips as 'directory'"

# Human-readable text mode on populated catalog.
OUT_LIST_TEXT_POP="$(run_plugins_verb "T2 list (text/populated)" list)"
smoke_assert_contains "$OUT_LIST_TEXT_POP" "teams@agent-bridge" \
  "T2 list text mode includes teams@agent-bridge"
smoke_assert_contains "$OUT_LIST_TEXT_POP" "ms365@agent-bridge" \
  "T2 list text mode includes ms365@agent-bridge"

OUT_MKT_TEXT_POP="$(run_plugins_verb "T2 marketplaces (text/populated)" marketplaces)"
smoke_assert_contains "$OUT_MKT_TEXT_POP" "smoke-mkt" \
  "T2 marketplaces text mode includes smoke-mkt"
smoke_assert_contains "$OUT_MKT_TEXT_POP" "agent-bridge" \
  "T2 marketplaces text mode includes agent-bridge"

# ---------------------------------------------------------------------------
# T3: -h / --help honored on both verbs (rc=0, non-empty stdout, no
# error markers). 1117 universal gate covers the same property at the
# T2 layer; this smoke double-pins it inside the ζ track for fast
# local feedback.
# ---------------------------------------------------------------------------
smoke_log "T3: -h/--help rc=0 with usage output for list + marketplaces"

for verb in list marketplaces; do
  for flag in -h --help; do
    out="$("$AGB_FILE" plugins "$verb" "$flag" 2>&1)"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      smoke_fail "T3: plugins $verb $flag rc=$rc (expected 0); output: $out"
    fi
    if [[ ${#out} -eq 0 ]]; then
      smoke_fail "T3: plugins $verb $flag rc=0 but stdout empty"
    fi
    smoke_assert_contains "$out" "Usage:" "T3: plugins $verb $flag contains Usage:"
  done
done

# ---------------------------------------------------------------------------
# T4: `show` semantics unchanged — `show --json` still emits the
# documented show payload (plugin_count + marketplaces + populated).
# Sentinel against accidentally refactoring show into list/marketplaces.
# ---------------------------------------------------------------------------
smoke_log "T4: show --json still emits the documented show payload (sentinel)"

OUT_SHOW="$(run_plugins_verb "T4 show --json" show --json)"
assert_valid_json "T4 show --json parseable" "$OUT_SHOW"
OUT_TMP="$(mktemp)"
printf '%s' "$OUT_SHOW" >"$OUT_TMP"
HAS_POPULATED="$(python3 -c "
import json, sys
with open(sys.argv[1]) as h:
    d = json.load(h)
print('populated' in d)
" "$OUT_TMP")"
HAS_PLUGIN_COUNT="$(python3 -c "
import json, sys
with open(sys.argv[1]) as h:
    d = json.load(h)
print('plugin_count' in d)
" "$OUT_TMP")"
rm -f "$OUT_TMP"
smoke_assert_eq "True" "$HAS_POPULATED" "T4 show --json still emits 'populated'"
smoke_assert_eq "True" "$HAS_PLUGIN_COUNT" "T4 show --json still emits 'plugin_count'"

smoke_log "passed"
exit 0
