#!/usr/bin/env bash
# scripts/smoke/2171-rotate-live-preflight.sh — regression for issue #2171
# (operator incident #19460 M4 fleet-down).
#
# `bridge-auth.py rotate` selected a rotation candidate from STALE registry
# health flags (rotation_candidate_availability, fail-open). On a fleet-down
# incident that can pick a stale/limited token, which the daemon then syncs
# fleet-wide → fleet-wide outage. PR-B1 adds an opt-in `--preflight` that
# LIVE-probes the selected candidate (the cmd_check probe) BEFORE committing the
# active pointer: authorize ONLY on `available`; quota/auth/timeout/failed/403/
# unknown EXCLUDE the candidate; persist bounded failed-candidate evidence; and
# revalidate (active id, candidate row, fingerprint, enabled, fresh availability)
# at commit so a probe that raced a concurrent mutation is discarded, never
# committed onto the wrong row. With `--preflight` OFF, behavior is unchanged.
#
# Coverage:
#   PY  — scripts/smoke/2171-rotate-live-preflight-helper.py drives the 4 brief
#         cases with an INJECTED probe (fake claude via BRIDGE_CLAUDE_TOKEN_CHECK_BIN,
#         NO network, MOCK tokens) + the --preflight-OFF regression guard:
#           1 available -> commit (+ proof the probe runs lock-RELEASED);
#           2 quota/auth/403/timeout adverse -> next ring candidate, bounded one
#             pass, bounded failure evidence persisted (never permanent disable);
#           3 every candidate adverse -> skipped:all_tokens_limited, zero mutation;
#           4 candidate replaced mid-probe -> stale probe DISCARDED, wrong-row
#             commit 0, recover to a still-valid candidate;
#           OFF -> legacy stale-flag cascade, candidate NEVER live-probed.
#   S1  — wrapper sync contract preserved: bridge-auth.sh still triggers the
#         agent sync ONLY on status==rotated, and passes `rotate "$@"` so
#         --preflight reaches bridge-auth.py.
#   S2  — token-kind fail-closed: the preflight path probes ONLY a confirmed OAT
#         (TOKEN_KIND_OAUTH_OAT); a non-OAT candidate is excluded with an explicit
#         reason (never a wrong-protocol OAuth probe).
#   S3  — lock dance: the live probe runs OUTSIDE registry_lock, and the commit
#         is gated on a fresh-view revalidate (active id + candidate fingerprint).
#   S4  — footgun #11: no heredoc-stdin into a python3 subprocess in the smoke or
#         its helper.

set -euo pipefail

SMOKE_NAME="2171-rotate-live-preflight"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

AUTH_PY="$REPO_ROOT/bridge-auth.py"
AUTH_SH="$REPO_ROOT/bridge-auth.sh"
HELPER="$SCRIPT_DIR/2171-rotate-live-preflight-helper.py"

# Hermetic: never touch the live runtime / token registry.
unset BRIDGE_HOME BRIDGE_RUNTIME_CONFIG_FILE BRIDGE_RUNTIME_ROOT BRIDGE_STATE_DIR 2>/dev/null || true

failed=0
fail() { echo "  FAIL  $1" >&2; failed=1; }
ok() { echo "  PASS  $1"; }

# --- PY: behavioral harness (the bulk of coverage; injected probe, no network) -
echo "[PY] injected-probe rotation scenarios (4 cases + --preflight-OFF regression)"
if python3 "$HELPER"; then
  ok "python harness: all rotation assertions pass"
else
  fail "python harness: one or more rotation assertions failed"
fi

# --- S1: wrapper sync contract preserved -------------------------------------
echo "[S1] bridge-auth.sh sync triggers only on status==rotated + passes --preflight through"
if grep -qE '"\$rotate_status" == "rotated"' "$AUTH_SH"; then
  ok "wrapper gates the agent sync on rotate_status==rotated"
else
  fail "wrapper sync gate (rotate_status==rotated) missing — sync trigger contract drifted"
fi
if grep -qE 'rotate "\$@"' "$AUTH_SH"; then
  ok "wrapper passes 'rotate \"\$@\"' so --preflight/--preflight-timeout reach bridge-auth.py"
else
  fail "wrapper does not pass rotate \"\$@\" through — --preflight cannot reach python"
fi

# --- S2: token-kind fail-closed in the preflight path ------------------------
echo "[S2] preflight probes ONLY a confirmed OAT (non-OAT fail-closed)"
preflight_fn="$(awk '/^def _cmd_rotate_preflight\(/{f=1} f{print} /^def cmd_rotate\(/{if(f)exit}' "$AUTH_PY")"
if printf '%s\n' "$preflight_fn" | grep -qE 'candidate_kind != TOKEN_KIND_OAUTH_OAT'; then
  ok "non-OAT candidate is excluded (no silent wrong-protocol OAuth probe)"
else
  fail "preflight does not fail-closed on non-OAT token kind"
fi
if printf '%s\n' "$preflight_fn" | grep -qE 'preflight_unsupported_kind'; then
  ok "non-OAT exclusion carries an explicit reason"
else
  fail "non-OAT exclusion reason is not explicit"
fi

# --- S3: lock dance — unlocked probe + revalidate-at-commit -------------------
echo "[S3] live probe runs OUTSIDE registry_lock; commit gated on fresh-view revalidate"
if printf '%s\n' "$preflight_fn" | grep -qE 'probe_claude_token\(candidate_token, preflight_timeout\)'; then
  ok "preflight calls probe_claude_token with the short preflight budget"
else
  fail "preflight does not invoke probe_claude_token(candidate_token, preflight_timeout)"
fi
# The probe must NOT be indented deeper than the `with registry_lock` blocks
# (which would mean it runs UNDER the lock). It sits at the per-candidate loop
# base (16 spaces) — a SIBLING of the Step A snapshot lock and the Step C commit
# lock, between them — the cmd_check unlocked-probe shape. A nested probe would
# be at >=20 spaces.
probe_indent="$(printf '%s\n' "$preflight_fn" | grep -nE 'probe = probe_claude_token\(candidate_token' | head -n1)"
if printf '%s\n' "$preflight_fn" | grep -qE '^                probe = probe_claude_token\(candidate_token' \
   && ! printf '%s\n' "$preflight_fn" | grep -qE '^                    probe = probe_claude_token\(candidate_token'; then
  ok "probe runs at the loop-base indentation (sibling of the locks, not nested under registry_lock)"
else
  fail "probe is not at the unlocked loop-base indentation — may run under the lock ($probe_indent)"
fi
if printf '%s\n' "$preflight_fn" | grep -qE 'active_now == old_id' \
   && printf '%s\n' "$preflight_fn" | grep -qE 'live_fp == candidate_fp'; then
  ok "commit revalidates active-id unchanged AND candidate fingerprint match"
else
  fail "commit revalidate (active_now==old_id + live_fp==candidate_fp) missing"
fi
if printf '%s\n' "$preflight_fn" | grep -qE 'revalidation_failed'; then
  ok "a raced probe is deterministically discarded (revalidation_failed), never committed"
else
  fail "no deterministic discard path for a raced/stale probe"
fi

# --- S4: footgun #11 — no heredoc-stdin into python3 in the smoke/helper ------
echo "[S4] footgun #11: smoke + helper invoke python3 by file path (no heredoc-stdin)"
# Build the redirect tokens at runtime so this scanner line itself does not
# contain the literal operators the sister heredoc-ban lint matches on.
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
