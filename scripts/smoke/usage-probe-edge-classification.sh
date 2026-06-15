#!/usr/bin/env bash
# scripts/smoke/usage-probe-edge-classification.sh — regression for the
# CDN-edge-block misclassification of the native usage probe.
#
# Field incident: every `GET api/oauth/usage` response was served by the CDN
# EDGE (`Server: cloudflare`, NO `request-id`/`anthropic-*` origin headers,
# Retry-After pinned at 3600, the same token flapping 403<->429) while live
# sessions on the SAME account ran fine. The probe's body-only 429 check
# misread the edge block as ACCOUNT quota → synthetic at-limit cache →
# usage-alert storms + rotation ping-pong; the fixed 60s cooldown re-struck
# the edge every ~6 min, permanently renewing the edge ban window.
#
# Fix surface covered here:
#   PY — scripts/smoke/usage-probe-edge-classification-helper.py drives every
#        scenario against the REAL run_probe + REAL monitor with an injected
#        HTTP seam (no live network, mock tokens only): 3-way 429/403
#        classification, per-token exponential backoff (5m→15m→60m cap,
#        Retry-After honored, no call while cooling down, rotated-in token
#        probes immediately), synthetic-signal alert isolation (rotation lane
#        only, zero operator alerts), cache token attribution (probe + monitor
#        stale guard, fail-open for real readings), statusLine-tap freshness
#        priority, audit TSV `-` sentinel, credential safety.
#   S1 — in-source wiring greps: classifier + backoff in the probe, the
#        --active-token-digest plumbing, the sentinel decode in the wrapper,
#        edge-blocked in the audit parser's noteworthy set.
#   F1 — bash-side TSV consumer: the `-` sentinel keeps http_status in its own
#        column through a real `IFS=$'\t' read` (the original field-collapse
#        bug shifted it into reset_at).
#   E1 — ensure-hud-usage-tap installs the tap STANDALONE when the statusLine
#        slot is empty ({} or absent), is idempotent, reports `present` via
#        status-hud-usage-tap, and never clobbers a foreign statusLine.

set -euo pipefail

SMOKE_NAME="usage-probe-edge-classification"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

PROBE="$REPO_ROOT/bridge-usage-probe.py"
USAGE_PY="$REPO_ROOT/bridge-usage.py"
USAGE_SH="$REPO_ROOT/bridge-usage.sh"
HELPERS_PY="$REPO_ROOT/bridge-daemon-helpers.py"
HOOKS_PY="$REPO_ROOT/bridge-hooks.py"
HELPER="$SCRIPT_DIR/usage-probe-edge-classification-helper.py"

failed=0
fail() {
  echo "  FAIL  $1" >&2
  failed=1
}
ok() { echo "  PASS  $1"; }

# --- PY: the mock-only python harness (the bulk of behavioral coverage) ------
echo "[PY] mock-only classification/backoff/isolation scenarios (no live network)"
if python3 "$HELPER"; then
  ok "python harness: all edge-classification scenarios pass"
else
  fail "python harness: one or more edge-classification scenarios failed"
fi

# --- S1: in-source wiring -----------------------------------------------------
echo "[S1] in-source wiring"
if grep -q 'def classify_probe_http_error' "$PROBE" && grep -q 'CLASSIFICATION_EDGE_BLOCKED' "$PROBE"; then
  ok "probe ships the 3-way classifier (classify_probe_http_error / edge-blocked)"
else
  fail "probe missing the 3-way classifier"
fi
if grep -q 'def record_token_cooldown' "$PROBE" && grep -q 'EDGE_BACKOFF_SCHEDULE_SECONDS' "$PROBE"; then
  ok "probe ships the per-token exponential backoff (record_token_cooldown)"
else
  fail "probe missing the per-token backoff"
fi
if grep -q 'active-token-digest' "$PROBE" && grep -q -- '--active-token-digest' "$USAGE_PY" \
   && grep -q -- '--active-token-digest' "$USAGE_SH"; then
  ok "active-token-digest plumbing present (probe CLI → wrapper → monitor)"
else
  fail "active-token-digest plumbing incomplete"
fi
if grep -q '"edge-blocked"' "$HELPERS_PY"; then
  ok "edge-blocked is a noteworthy audit status in usage-probe-result-parse"
else
  fail "edge-blocked missing from the audit parser's noteworthy set"
fi
if grep -q '== "-" \]\] && p_reset=""' "$USAGE_SH"; then
  ok "wrapper decodes the \`-\` sentinel back to empty fields"
else
  fail "wrapper missing the \`-\` sentinel decode"
fi
if grep -q '"signal"' "$USAGE_PY" && grep -q 'bucket = "signal"' "$USAGE_PY"; then
  ok "monitor routes synthetic signal snapshots to the signal bucket (no operator alerts)"
else
  fail "monitor missing the signal bucket isolation"
fi

# --- F1: bash-side TSV consumer survives empty middle columns -----------------
echo "[F1] bash TSV consumer: http_status stays in its own column via the \`-\` sentinel"
f1_row="$(python3 "$HELPERS_PY" usage-probe-result-parse '{"status":"degraded","http_status":403}')"
f1_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-edge-f1.XXXXXX")"
printf '%s\n' "$f1_row" >"$f1_tmp"
f1_status="" f1_reset="" f1_retry="" f1_http="" f1_detail=""
IFS=$'\t' read -r f1_status f1_reset f1_retry f1_http f1_detail <"$f1_tmp"
rm -f -- "$f1_tmp"
[[ "$f1_reset" == "-" ]] && f1_reset=""
[[ "$f1_retry" == "-" ]] && f1_retry=""
[[ "$f1_http" == "-" ]] && f1_http=""
[[ "$f1_detail" == "-" ]] && f1_detail=""
if [[ "$f1_status" == "degraded" && "$f1_http" == "403" && -z "$f1_reset" && -z "$f1_retry" ]]; then
  ok "http_status=403 decoded in column 4 with empty reset/retry (no field collapse)"
else
  fail "TSV consumer field shift: status=$f1_status reset=$f1_reset retry=$f1_retry http=$f1_http"
fi

# --- E1: ensure-hud-usage-tap fresh-install on an empty statusLine slot -------
echo "[E1] ensure-hud-usage-tap installs the tap standalone when statusLine is empty"
E1_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-edge-hudtap.XXXXXX")"
mkdir -p "$E1_WORKDIR/.claude"
printf '%s' '{}' >"$E1_WORKDIR/.claude/settings.json"
E1_OUT="$(python3 "$HOOKS_PY" ensure-hud-usage-tap --workdir "$E1_WORKDIR" --bridge-home "$REPO_ROOT" --python-bin "$(command -v python3)")"
if printf '%s' "$E1_OUT" | grep -q "status: installed" \
   && grep -q 'hud-usage-tap' "$E1_WORKDIR/.claude/settings.json"; then
  ok "empty settings ({}) → tap installed standalone"
else
  fail "empty settings did not install the tap (out=$E1_OUT)"
fi
# Idempotent second run reports present and does not change the file.
E1_HASH_BEFORE="$(cksum "$E1_WORKDIR/.claude/settings.json")"
E1_OUT2="$(python3 "$HOOKS_PY" ensure-hud-usage-tap --workdir "$E1_WORKDIR" --bridge-home "$REPO_ROOT" --python-bin "$(command -v python3)")"
E1_HASH_AFTER="$(cksum "$E1_WORKDIR/.claude/settings.json")"
if printf '%s' "$E1_OUT2" | grep -q "status: present" && [[ "$E1_HASH_BEFORE" == "$E1_HASH_AFTER" ]]; then
  ok "second run is an idempotent no-op (present)"
else
  fail "second run not idempotent (out=$E1_OUT2)"
fi
# status-hud-usage-tap recognizes the standalone tap as present.
if python3 "$HOOKS_PY" status-hud-usage-tap --workdir "$E1_WORKDIR" --bridge-home "$REPO_ROOT" | grep -q "status: present"; then
  ok "status-hud-usage-tap reports the standalone tap as present"
else
  fail "status-hud-usage-tap does not recognize the standalone tap"
fi
rm -rf "$E1_WORKDIR"

# Absent statusLine KEY entirely → also installs.
E2_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-edge-hudtap2.XXXXXX")"
mkdir -p "$E2_WORKDIR/.claude"
printf '%s' '{"model":"opus"}' >"$E2_WORKDIR/.claude/settings.json"
E2_OUT="$(python3 "$HOOKS_PY" ensure-hud-usage-tap --workdir "$E2_WORKDIR" --bridge-home "$REPO_ROOT" --python-bin "$(command -v python3)")"
if printf '%s' "$E2_OUT" | grep -q "status: installed" \
   && grep -q '"model": "opus"' "$E2_WORKDIR/.claude/settings.json"; then
  ok "absent statusLine key → installed; sibling settings preserved"
else
  fail "absent statusLine key not handled (out=$E2_OUT)"
fi
rm -rf "$E2_WORKDIR"

# A foreign (non-HUD, non-empty) statusLine is NEVER clobbered.
E3_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-edge-hudtap3.XXXXXX")"
mkdir -p "$E3_WORKDIR/.claude"
printf '%s' '{"statusLine":{"type":"command","command":"my-custom-statusline --fancy"}}' >"$E3_WORKDIR/.claude/settings.json"
E3_HASH_BEFORE="$(cksum "$E3_WORKDIR/.claude/settings.json")"
E3_OUT="$(python3 "$HOOKS_PY" ensure-hud-usage-tap --workdir "$E3_WORKDIR" --bridge-home "$REPO_ROOT" --python-bin "$(command -v python3)" || true)"
E3_HASH_AFTER="$(cksum "$E3_WORKDIR/.claude/settings.json")"
if printf '%s' "$E3_OUT" | grep -q "status: no-hud" && [[ "$E3_HASH_BEFORE" == "$E3_HASH_AFTER" ]]; then
  ok "foreign statusLine left untouched (no-hud)"
else
  fail "foreign statusLine was modified or misreported (out=$E3_OUT)"
fi
rm -rf "$E3_WORKDIR"

if [[ "$failed" -ne 0 ]]; then
  echo "[smoke:${SMOKE_NAME}] FAILED"
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] PASS"
