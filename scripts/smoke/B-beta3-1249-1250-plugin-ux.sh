#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/B-beta3-1249-1250-plugin-ux.sh
#
# Lane B of v0.15.0-beta3 — plugin UX bundle: #1249 + #1250.
#
#   #1249: integrated `agb plugins add-marketplace <url-or-path>
#          [--channels ...]` verb. Clone+register a marketplace, run
#          seed, apply iso v2 chmod — in one call. Also: `agb plugins
#          help install` informational advisory for `claude plugin
#          install` users on iso v2 hosts.
#
#   #1250: `agb plugins seed` MUST NOT silently allow node_modules=missing
#          + criticality=channel-required + plugin declares deps. Default:
#          auto-run `bun install` in the source dir and re-sync. Failure
#          mode: fail-loud + seed_status=incomplete on channel-required.
#          `--no-auto-install` opts out (still fail-loud on the gap).
#
# Test plan:
#   T1. `add-marketplace <local-path> --channels plugin:<name>@<id>`
#       resolves to the path, delegates to seed, and writes the catalog
#       manifests. The mirror dir under
#       $BRIDGE_SHARED_ROOT/plugins-cache/marketplaces/<id>/ is created.
#   T2. `add-marketplace` idempotency: running twice with the same path
#       returns rc=0 both times, no destructive side-effect.
#   T3. Auto-install path: `agb plugins seed --marketplace-root
#       <fixture-with-missing-node-modules>` parses the sync output,
#       detects node_modules=missing + declared deps + channel-required,
#       runs bun install (stubbed), then re-syncs, then verifies. With
#       the install stub succeeding (drops a node_modules dir), the
#       second sync reports node_modules=present and seed exits 0.
#       Skipped when neither bun nor npm is available AND we cannot
#       provide a stub (rare — the stub is fully self-contained).
#   T4. Auto-install opt-out path: same fixture, but pass
#       `--no-auto-install`. Seed MUST exit non-zero with a fail-loud
#       message naming the affected plugin and `bun install`.
#   T5. `agb plugins help install` returns exit 0 with output that
#       contains the iso v2 advisory text (mention `agb plugins seed`
#       AND `add-marketplace`).
#   T6 (teeth — #1250): if the auto-install pass were stripped from
#       bridge_plugins_cmd_seed, T3 would fail with a stale seed (the
#       fixture's first sync produces node_modules=missing and the
#       auto-install branch is what fixes it). The "teeth" assertion
#       is performed by SIMULATING the strip: invoke seed with the
#       stub bun replaced by an always-fail binary AND
#       --no-auto-install OFF. Result: seed must STILL exit non-zero
#       (fail-loud) — proves the fail-loud branch fires, not the silent
#       ride-through that #1250 reverted.
#   T7 (teeth — #1249): if `add-marketplace` were absent from the
#       dispatcher, `agb plugins add-marketplace ...` would fall through
#       to the "지원하지 않는" arm with exit 2. We invoke
#       `agb plugins add-marketplace` against a deliberately-invalid
#       target (`/dev/null`) and assert the error message says
#       "is not an existing directory" rather than "지원하지 않는" —
#       proving the verb is registered AND validating its target check.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout).
# The fixture marketplace is built inline under $SMOKE_TMP_ROOT — no
# network calls. A stub `bun` binary is provided on PATH for T3/T6.
#
# Platform: macOS dev + Linux CI. The iso v2 chmod branches inside seed
# are macOS-noop via the platform discriminator (lib/bridge-isolation-v2.sh).
#
# Footgun #11: every captured subprocess uses `out=$(... 2>&1)`. No
# `<<EOF` to subprocess, no `<<<` here-strings. Driver bodies are
# emitted with printf-to-file.

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:B-beta3-1249-1250-plugin-ux][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="B-beta3-1249-1250-plugin-ux"
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

smoke_assert_file_exists "$AGB_FILE" "agent-bridge dispatcher present"
smoke_assert_file_exists "$REPO_ROOT/bridge-plugins.sh" "bridge-plugins.sh present"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi
export BRIDGE_BASH_BIN="$BRIDGE_BASH"

# Fixture: synthetic external marketplace with a single plugin that
# declares deps via package.json. node_modules is intentionally absent
# at first — the auto-install pass is what synthesizes it.
FIXTURE_MKT="$SMOKE_TMP_ROOT/fixture-mkt"
FIXTURE_PLUGIN="$FIXTURE_MKT/plugins/fixture-plugin"
FIXTURE_MKT_NAME="fixture-mkt"
mkdir -p "$FIXTURE_MKT/.claude-plugin" \
         "$FIXTURE_PLUGIN/.claude-plugin"

cat >"$FIXTURE_MKT/.claude-plugin/marketplace.json" <<JSON
{
  "name": "$FIXTURE_MKT_NAME",
  "owner": {"name": "smoke"},
  "plugins": [
    {"name": "fixture-plugin", "source": "./plugins/fixture-plugin", "version": "0.0.1"}
  ]
}
JSON

cat >"$FIXTURE_PLUGIN/.claude-plugin/plugin.json" <<JSON
{"name": "fixture-plugin", "version": "0.0.1"}
JSON

cat >"$FIXTURE_PLUGIN/package.json" <<JSON
{
  "name": "fixture-plugin",
  "version": "0.0.1",
  "dependencies": {
    "left-pad": "1.3.0"
  }
}
JSON

# Stage a stub `bun` binary on PATH. T1/T2/T3 all use it; T6 swaps to a
# failing variant. The stub materializes node_modules with a dummy
# left-pad package so the post-install re-sync flips node_modules=missing
# → node_modules=present, which is what seed parses to clear the gap.
STUB_BIN_DIR="$SMOKE_TMP_ROOT/stubbin"
mkdir -p "$STUB_BIN_DIR"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -e\n'
  printf 'if [[ "$1" == "install" ]]; then\n'
  printf '  mkdir -p node_modules/left-pad\n'
  printf '  printf "%%s\\n" "{\\"name\\":\\"left-pad\\",\\"version\\":\\"1.3.0\\"}" >node_modules/left-pad/package.json\n'
  printf '  exit 0\n'
  printf 'fi\n'
  printf 'exit 0\n'
} >"$STUB_BIN_DIR/bun"
chmod +x "$STUB_BIN_DIR/bun"

# ----------------------------------------------------------------------------
# T1: add-marketplace with a local PATH — clones-or-canonicalizes,
# delegates to seed (default = auto-install ON), runs the stub bun for
# node_modules resolution, lands the catalog + mirror.
# ----------------------------------------------------------------------------
smoke_log "T1: add-marketplace <path> --channels delegates to seed (auto-install + stub bun)"

rm -rf "$FIXTURE_PLUGIN/node_modules" 2>/dev/null || true

T1_OUT=""
T1_RC=0
T1_OUT="$(PATH="$STUB_BIN_DIR:$PATH" "$BRIDGE_BASH" "$REPO_ROOT/bridge-plugins.sh" add-marketplace \
            "$FIXTURE_MKT" \
            --channels "plugin:fixture-plugin@$FIXTURE_MKT_NAME" 2>&1)" \
  || T1_RC=$?
if (( T1_RC != 0 )); then
  printf '%s\n' "$T1_OUT" >&2
  smoke_fail "T1: add-marketplace with auto-install (stub bun on PATH) should exit 0 (got rc=$T1_RC): $T1_OUT"
fi

# Catalog and mirror must exist after a successful add-marketplace.
smoke_assert_file_exists "$PLUGINS_CACHE/installed_plugins.json" \
  "T1 installed_plugins.json present after add-marketplace"
[[ -d "$PLUGINS_CACHE/marketplaces/$FIXTURE_MKT_NAME" ]] \
  || smoke_fail "T1: mirror dir $PLUGINS_CACHE/marketplaces/$FIXTURE_MKT_NAME missing"
smoke_assert_contains "$T1_OUT" "[plugins add-marketplace]" \
  "T1 add-marketplace verb tagged its own log lines"
smoke_assert_contains "$T1_OUT" "$FIXTURE_MKT" \
  "T1 add-marketplace echoed resolved path"
smoke_assert_contains "$T1_OUT" "[ok] seeded" \
  "T1 add-marketplace delegated seed completed with [ok] seeded"
[[ -d "$FIXTURE_PLUGIN/node_modules/left-pad" ]] \
  || smoke_fail "T1: stub bun was supposed to materialize node_modules/left-pad — not found"

# ----------------------------------------------------------------------------
# T2: add-marketplace idempotency — second invocation also exits 0, and
# the catalog + mirror stay intact (no destructive --delete sweep).
# ----------------------------------------------------------------------------
smoke_log "T2: add-marketplace idempotent on re-run"

T2_OUT=""
T2_RC=0
T2_OUT="$(PATH="$STUB_BIN_DIR:$PATH" "$BRIDGE_BASH" "$REPO_ROOT/bridge-plugins.sh" add-marketplace \
            "$FIXTURE_MKT" \
            --channels "plugin:fixture-plugin@$FIXTURE_MKT_NAME" 2>&1)" \
  || T2_RC=$?
if (( T2_RC != 0 )); then
  printf '%s\n' "$T2_OUT" >&2
  smoke_fail "T2: second add-marketplace exited non-zero (got rc=$T2_RC): $T2_OUT"
fi
smoke_assert_file_exists "$PLUGINS_CACHE/installed_plugins.json" \
  "T2 installed_plugins.json present after second add-marketplace"
[[ -d "$PLUGINS_CACHE/marketplaces/$FIXTURE_MKT_NAME" ]] \
  || smoke_fail "T2: mirror dir vanished after second add-marketplace"
smoke_assert_contains "$T2_OUT" "[plugins add-marketplace]" \
  "T2 add-marketplace second invocation tags lines (verb still registered)"

# T3/T4/T6 each need a FRESH fixture (the cache from T1/T2 already has
# node_modules, which makes the dev-plugin-cache helper report
# node_modules=present even when the source dir's node_modules has been
# removed — the helper reports based on the cache, not the source).
# Build a per-test fixture marketplace under $SMOKE_TMP_ROOT.
build_fresh_fixture() {
  local label="$1"
  local mkt_root="$SMOKE_TMP_ROOT/fixture-mkt-$label"
  local plugin_dir="$mkt_root/plugins/p-$label"
  local mkt_name="fixture-mkt-$label"
  mkdir -p "$mkt_root/.claude-plugin" "$plugin_dir/.claude-plugin"
  {
    printf '{"name": "%s", "owner": {"name": "smoke"}, "plugins": [\n' "$mkt_name"
    printf '  {"name": "p-%s", "source": "./plugins/p-%s", "version": "0.0.1"}\n' "$label" "$label"
    printf ']}\n'
  } >"$mkt_root/.claude-plugin/marketplace.json"
  printf '{"name": "p-%s", "version": "0.0.1"}\n' "$label" \
    >"$plugin_dir/.claude-plugin/plugin.json"
  printf '{"name": "p-%s", "version": "0.0.1", "dependencies": {"left-pad": "1.3.0"}}\n' "$label" \
    >"$plugin_dir/package.json"
  printf '%s' "$mkt_root"
}

# ----------------------------------------------------------------------------
# T3: auto-install — stub bun appears on PATH, fixture's node_modules
# is missing, seed should run the stub which materializes node_modules,
# then re-sync, then exit 0.
# ----------------------------------------------------------------------------
smoke_log "T3: auto-install — stub bun runs, node_modules materializes, seed exits 0"

T3_MKT="$(build_fresh_fixture "t3")"
T3_MKT_NAME="fixture-mkt-t3"
T3_PLUGIN_DIR="$T3_MKT/plugins/p-t3"

# Run seed against a fresh fixture WITHOUT --no-auto-install. The stub
# bun is on PATH; seed must detect the gap, run bun install (stub), and
# re-sync.
T3_OUT=""
T3_RC=0
T3_OUT="$(PATH="$STUB_BIN_DIR:$PATH" "$BRIDGE_BASH" "$REPO_ROOT/bridge-plugins.sh" seed \
            --marketplace-root "$T3_MKT" \
            --channels "plugin:p-t3@$T3_MKT_NAME" 2>&1)" \
  || T3_RC=$?
if (( T3_RC != 0 )); then
  printf '%s\n' "$T3_OUT" >&2
  smoke_fail "T3: seed with auto-install + working stub bun should exit 0 (got rc=$T3_RC): $T3_OUT"
fi
[[ -d "$T3_PLUGIN_DIR/node_modules/left-pad" ]] \
  || smoke_fail "T3: stub bun was supposed to materialize node_modules/left-pad — not found. T3_OUT was: $T3_OUT"
smoke_assert_contains "$T3_OUT" "auto-install" \
  "T3 seed output contains auto-install marker (auto-install branch fired)"
smoke_assert_contains "$T3_OUT" "[ok] seeded" \
  "T3 seed output ends in [ok] seeded after successful auto-install"

# ----------------------------------------------------------------------------
# T4: --no-auto-install opt-out — fail-loud on the gap.
# ----------------------------------------------------------------------------
smoke_log "T4: --no-auto-install must fail-loud on node_modules=missing + channel-required"

T4_MKT="$(build_fresh_fixture "t4")"
T4_MKT_NAME="fixture-mkt-t4"

T4_OUT=""
T4_RC=0
T4_OUT="$("$BRIDGE_BASH" "$REPO_ROOT/bridge-plugins.sh" seed \
            --marketplace-root "$T4_MKT" \
            --channels "plugin:p-t4@$T4_MKT_NAME" \
            --no-auto-install 2>&1)" \
  || T4_RC=$?
[[ "$T4_RC" -ne 0 ]] \
  || smoke_fail "T4: --no-auto-install must exit non-zero on channel-required gap (got rc=0: $T4_OUT)"
smoke_assert_contains "$T4_OUT" "node_modules=missing" \
  "T4 fail-loud message names node_modules=missing"
smoke_assert_contains "$T4_OUT" "bun install" \
  "T4 fail-loud message mentions 'bun install' remediation"

# ----------------------------------------------------------------------------
# T5: `agb plugins help install` advisory.
# ----------------------------------------------------------------------------
smoke_log "T5: agb plugins help install renders iso v2 advisory"

T5_OUT=""
T5_RC=0
T5_OUT="$("$BRIDGE_BASH" "$REPO_ROOT/bridge-plugins.sh" help install 2>&1)" \
  || T5_RC=$?
if (( T5_RC != 0 )); then
  smoke_fail "T5: plugins help install rc=$T5_RC: $T5_OUT"
fi
smoke_assert_contains "$T5_OUT" "agb plugins seed" \
  "T5 advisory mentions 'agb plugins seed'"
smoke_assert_contains "$T5_OUT" "add-marketplace" \
  "T5 advisory mentions 'add-marketplace'"
smoke_assert_contains "$T5_OUT" "isolation-v2" \
  "T5 advisory mentions 'isolation-v2'"

# ----------------------------------------------------------------------------
# T6 (teeth): if #1250's fail-loud branch were absent, a failing
# auto-install would silently ride through. We force the install to
# fail by staging a NEGATIVE-RC stub bun and asserting seed STILL
# exits non-zero AND emits the documented structured tokens
# (codex r1 BLOCKING): `seed_status=incomplete`,
# `node_modules=install_failed`, `criticality=channel-required`.
# Without these tokens, operators + CI cannot grep the output to
# distinguish the fail-loud branch from an unrelated bridge_die.
# Teeth: revert the new token emission → T6 fails with EXACT message
# "Lane B r1 finding 1 — seed_status=incomplete missing on auto-install
# failure".
# ----------------------------------------------------------------------------
smoke_log "T6 (teeth #1250): failing auto-install must fail-loud with structured tokens (codex r1)"

FAILING_BIN_DIR="$SMOKE_TMP_ROOT/failbin"
mkdir -p "$FAILING_BIN_DIR"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "fail-stub: simulated bun install error" >&2\n'
  printf 'exit 1\n'
} >"$FAILING_BIN_DIR/bun"
chmod +x "$FAILING_BIN_DIR/bun"

T6_MKT="$(build_fresh_fixture "t6")"
T6_MKT_NAME="fixture-mkt-t6"

T6_OUT=""
T6_RC=0
T6_OUT="$(PATH="$FAILING_BIN_DIR:$PATH" "$BRIDGE_BASH" "$REPO_ROOT/bridge-plugins.sh" seed \
            --marketplace-root "$T6_MKT" \
            --channels "plugin:p-t6@$T6_MKT_NAME" 2>&1)" \
  || T6_RC=$?
[[ "$T6_RC" -ne 0 ]] \
  || smoke_fail "T6: failing bun install MUST cause seed to fail-loud (got rc=0: $T6_OUT)"
smoke_assert_contains "$T6_OUT" "auto-install" \
  "T6 fail message references the auto-install pass"
# codex r1 BLOCKING — assert the documented structured token contract.
# These three lines on the same output were absent at PR head ae39b18
# despite the smoke header lines 13-17 documenting the contract; r2
# emits them via _bridge_plugins_emit_seed_failure_tokens at every
# fail-loud die site.
if ! printf '%s\n' "$T6_OUT" | grep -q "seed_status=incomplete"; then
  smoke_fail "T6: Lane B r1 finding 1 — seed_status=incomplete missing on auto-install failure. T6_OUT=$T6_OUT"
fi
if ! printf '%s\n' "$T6_OUT" | grep -q "node_modules=install_failed"; then
  smoke_fail "T6: Lane B r1 finding 1 — node_modules=install_failed token missing on auto-install failure. T6_OUT=$T6_OUT"
fi
if ! printf '%s\n' "$T6_OUT" | grep -q "criticality=channel-required"; then
  smoke_fail "T6: Lane B r1 finding 1 — criticality=channel-required token missing on auto-install failure (contract is criticality-conditional). T6_OUT=$T6_OUT"
fi

# ----------------------------------------------------------------------------
# T7 (teeth): if add-marketplace verb were absent from the dispatcher,
# `agb plugins add-marketplace ...` would fall through to the "지원하지
# 않는" branch and exit 2. We invoke against an INVALID target and
# expect the dispatcher to recognize the verb AND the verb to validate
# its argument (different error path than "unknown command").
# ----------------------------------------------------------------------------
smoke_log "T7 (teeth #1249): add-marketplace verb is registered (not 'unknown command')"

T7_OUT=""
T7_RC=0
T7_OUT="$("$BRIDGE_BASH" "$REPO_ROOT/bridge-plugins.sh" add-marketplace \
            "/dev/null" 2>&1)" \
  || T7_RC=$?
[[ "$T7_RC" -ne 0 ]] \
  || smoke_fail "T7: add-marketplace with invalid target should exit non-zero (got rc=0)"
# The verb-registered path produces "is not an existing directory and
# does not look like a clonable URL". The unregistered path would print
# "지원하지 않는 plugins 명령입니다". Assert the registered-verb error.
smoke_assert_contains "$T7_OUT" "is not an existing directory" \
  "T7 add-marketplace verb is registered and produced the target-validation error (NOT the 'unknown command' fall-through)"
smoke_assert_not_contains "$T7_OUT" "지원하지 않는 plugins 명령입니다" \
  "T7 add-marketplace did NOT fall through to the 'unknown command' arm"

smoke_log "passed"
exit 0
