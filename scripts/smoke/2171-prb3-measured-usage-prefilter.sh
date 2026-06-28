#!/usr/bin/env bash
# scripts/smoke/2171-prb3-measured-usage-prefilter.sh — regression for issue
# #2171 PR-B3 (operator incident #19460 M4 fleet-down, remaining selection gap).
#
# `rotation_candidate_availability` judged a candidate from LIGHT registry stamps
# (limited_until / disabled_until / adverse last_check_status) only — never the
# candidate's OWN measured usage — so a near-limit-but-unstamped token could be
# selected and then synced fleet-wide. PR-B3 adds a cheap selection-time
# prefilter: a token-free measured-usage index (token_digest -> per-window
# near-limit booleans) is built OUTSIDE registry_lock and injected into the SINGLE
# eligibility gate used by the legacy cascade + preflight Step A + preflight
# revalidation. Absent/stale/malformed/no-digest-match => FAIL OPEN to the
# existing registry-stamp behavior (additive; LTS / no-cache installs are a
# no-op). Part 2 surfaces a wrong-home cache-split as a diagnostic (no-signal
# only; no alternate-home search). The daemon `--preflight` live backstop is
# PR-B2 — this smoke is the B3 unit only.
#
# Coverage:
#   PY  — 2171-prb3-measured-usage-prefilter-helper.py drives the 6 asserted
#         plan-ok cases (+ a B2-dependency note assertion, case 7)
#         with hand-written mock `.usage-cache.json` fixtures (NO network, NO live
#         registry, MOCK tokens, one-way digests only).
#   S1  — single-gate contract: all THREE gate call sites inject
#         measured_usage_index (no bypassing one-off cascade check).
#   S2  — index is built BEFORE registry_lock in both rotate paths (no cache IO
#         under the lock).
#   S3  — reason string `measured_near_limit` is present and distinct from
#         `stale_flag_unavailable`.
#   S4  — Part 2 emits cache_split_diagnostics CONDITIONALLY (byte-identical
#         envelope when no split) and stays diagnostic-only (no alternate-home).
#   S5  — footgun #11: no heredoc-stdin into a python3/bash subprocess.

set -euo pipefail

SMOKE_NAME="2171-prb3-measured-usage-prefilter"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

AUTH_PY="$REPO_ROOT/bridge-auth.py"
USAGE_PY="$REPO_ROOT/bridge-usage.py"
HELPER="$SCRIPT_DIR/2171-prb3-measured-usage-prefilter-helper.py"

# Hermetic: never touch the live runtime / token registry / usage cache.
unset BRIDGE_HOME BRIDGE_RUNTIME_CONFIG_FILE BRIDGE_RUNTIME_ROOT BRIDGE_STATE_DIR 2>/dev/null || true

failed=0
fail() { echo "  FAIL  $1" >&2; failed=1; }
ok() { echo "  PASS  $1"; }

# --- PY: behavioral harness (mock fixtures, no network) ----------------------
echo "[PY] measured-usage prefilter + cache-split diagnostic (6 asserted cases + B2-dependency note)"
if python3 "$HELPER"; then
  ok "python harness: all prefilter/diagnostic assertions pass"
else
  fail "python harness: one or more assertions failed"
fi

# --- S1: single-gate contract — every call site injects the index ------------
echo "[S1] all three rotation_candidate_availability call sites inject measured_usage_index"
call_sites="$(grep -cE 'measured_usage_index=measured_index' "$AUTH_PY" || true)"
if [[ "$call_sites" == "3" ]]; then
  ok "exactly 3 gate call sites pass measured_usage_index (legacy cascade + Step A + revalidate)"
else
  fail "expected 3 gate call sites injecting measured_usage_index, found $call_sites"
fi

# --- S2: index built BEFORE the lock in both rotate paths --------------------
echo "[S2] measured-usage index built before registry_lock (no cache IO under the lock)"
preflight_fn="$(awk '/^def _cmd_rotate_preflight\(/{f=1} f{print} /^def cmd_rotate\(/{if(f)exit}' "$AUTH_PY")"
cmd_rotate_fn="$(awk '/^def cmd_rotate\(/{f=1} f{print} /^def cmd_check\(/{if(f)exit}' "$AUTH_PY")"
for label in "preflight:${preflight_fn}" "legacy:${cmd_rotate_fn}"; do
  name="${label%%:*}"
  body="${label#*:}"
  idx_line="$(printf '%s\n' "$body" | grep -nE '_measured_usage_index_from_args' | head -n1 | cut -d: -f1)"
  lock_line="$(printf '%s\n' "$body" | grep -nE 'with registry_lock\(' | head -n1 | cut -d: -f1)"
  if [[ -n "$idx_line" && -n "$lock_line" && "$idx_line" -lt "$lock_line" ]]; then
    ok "${name}: index built (line $idx_line) before first registry_lock (line $lock_line)"
  else
    fail "${name}: index build not proven before registry_lock (idx=$idx_line lock=$lock_line)"
  fi
done

# --- S3: stable + distinct reason string -------------------------------------
echo "[S3] reason 'measured_near_limit' present and distinct from 'stale_flag_unavailable'"
if grep -qE '"measured_near_limit"' "$AUTH_PY"; then
  ok "measured_near_limit reason string present"
else
  fail "measured_near_limit reason string missing"
fi
if grep -qE 'measured_usage_index' "$AUTH_PY" && grep -qiE 'no cache IO' "$AUTH_PY"; then
  ok "predicate documents no-cache-IO contract"
else
  fail "predicate no-cache-IO contract not documented"
fi

# --- S4: Part 2 conditional + diagnostic-only --------------------------------
echo "[S4] cache_split_diagnostics emitted conditionally; diagnostic-only (no alternate-home)"
if grep -qE 'if cache_split_diagnostics:' "$USAGE_PY"; then
  ok "diagnostics added to the envelope ONLY when a split is observed (byte-identical when inert)"
else
  fail "cache_split_diagnostics is not conditionally added (would change the steady-state envelope)"
fi
if grep -qE 'wrong_home_cache_split' "$USAGE_PY"; then
  ok "wrong-home cache-split reason present"
else
  fail "wrong_home_cache_split reason missing"
fi

# --- S5: footgun #11 — no heredoc-stdin into python3/bash --------------------
echo "[S5] footgun #11: smoke + helper invoke python3 by file path (no heredoc-stdin)"
lt='<'
redir_pattern="python3[^|]*${lt}${lt}|bash[[:space:]]+${lt}${lt}"
hd_hit=0
for f in "$SCRIPT_DIR/${SMOKE_NAME}.sh" "$HELPER"; do
  if grep -nE "$redir_pattern" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
    fail "heredoc-stdin into a subprocess found in $(basename "$f")"
    hd_hit=1
  fi
done
[[ "$hd_hit" -eq 0 ]] && ok "no heredoc-stdin into a python3/bash subprocess in the smoke or helper"

if [[ "$failed" -ne 0 ]]; then
  echo "[smoke:${SMOKE_NAME}] FAILED"
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] PASS"
