#!/usr/bin/env bash
# tests/surface-reply-enforce/smoke.sh
#
# Regression test for issues #415 (anchored reply scan) and #20739
# (channel-source prefix matching) — Stop hook input-source ↔
# output-reply enforcement.
#
# The hook reads a Claude Code Stop event from stdin (JSON with
# `transcript_path` and optional `stop_hook_active`), inspects the JSONL
# transcript at `transcript_path`, and emits
# `{"decision":"block","reason":"..."}` on stdout iff:
#
#   1. BRIDGE_AGENT_ID is non-empty (i.e. real agent session, not TUI-only)
#   2. The latest user turn carries a <channel source="<surface>"
#      chat_id="<id>" message_id="<id>"> tag for a supported surface
#      (discord/telegram/teams). Both legacy short form ("discord") and
#      current MCP plugin form ("plugin:discord:discord") are accepted.
#   3. No subsequent assistant turn invoked
#      mcp__plugin_<namespace>__reply with matching chat_id, where
#      <namespace> is "discord" for the legacy form and "discord_discord"
#      for the plugin form.
#   4. No subsequent assistant text emitted
#      <no-reply-needed source="<source>" chat_id="<id>" ...>
#      with `source` matching either the raw input source or the short
#      surface ("discord"/"telegram"/"teams").
#
# Otherwise it is silent and exits 0 (Stop proceeds).

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
HOOK="$REPO_ROOT/hooks/surface-reply-enforce.py"

log() { printf '[surface-reply-enforce] %s\n' "$*"; }
die() { printf '[surface-reply-enforce][error] %s\n' "$*" >&2; exit 1; }
pass() { printf '[surface-reply-enforce][pass] %s\n' "$*"; }

[[ -f "$HOOK" ]] || die "hook missing: $HOOK"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ──────────────────────────────────────────────────────────────────────
# Production format fixtures (issue #20739): source="plugin:discord:discord",
# reply tool "mcp__plugin_discord_discord__reply".
# ──────────────────────────────────────────────────────────────────────

write_transcript_with_reply() {
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:discord:discord\" chat_id=\"C123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"sending"},{"type":"tool_use","name":"mcp__plugin_discord_discord__reply","input":{"chat_id":"C123","content":"hi back"}}]}}
JSONL
}

write_transcript_missing_reply() {
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:discord:discord\" chat_id=\"C123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Here are three options: A/B/C."}]}}
JSONL
}

write_transcript_no_reply_marker_raw() {
  # Marker uses the raw production source verbatim.
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:discord:discord\" chat_id=\"C123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"bot noise; no reply needed.\n<no-reply-needed source=\"plugin:discord:discord\" chat_id=\"C123\" reason=\"bot ack\" />"}]}}
JSONL
}

write_transcript_no_reply_marker_short() {
  # Marker uses the short surface form even though channel input is in
  # plugin form. Backward-compat: still satisfies the gate.
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:discord:discord\" chat_id=\"C123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"bot noise; no reply needed.\n<no-reply-needed source=\"discord\" chat_id=\"C123\" reason=\"bot ack\" />"}]}}
JSONL
}

write_transcript_old_reply_new_unanswered() {
  # codex r1 #415 regression: an old reply must not satisfy a newer
  # unanswered turn from the same chat_id.
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:discord:discord\" chat_id=\"C123\" message_id=\"M111\" />\nfirst question"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"answering"},{"type":"tool_use","name":"mcp__plugin_discord_discord__reply","input":{"chat_id":"C123","content":"old reply"}}]}}
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:discord:discord\" chat_id=\"C123\" message_id=\"M222\" />\nsecond question — needs a fresh reply"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"thinking out loud, no reply tool"}]}}
JSONL
}

# ──────────────────────────────────────────────────────────────────────
# Legacy short-form fixtures (pre-#20739). Kept as regression coverage
# in case a future bridge revision emits the bare surface form.
# ──────────────────────────────────────────────────────────────────────

write_transcript_legacy_with_reply() {
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"discord\" chat_id=\"C123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"sending"},{"type":"tool_use","name":"mcp__plugin_discord__reply","input":{"chat_id":"C123","content":"hi back"}}]}}
JSONL
}

write_transcript_legacy_missing_reply() {
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"discord\" chat_id=\"C123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"prose only"}]}}
JSONL
}

write_transcript_tui_only() {
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"please show me the queue"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"sure"}]}}
JSONL
}

write_transcript_unsupported_plugin() {
  # Parseable plugin shape but surface not in SUPPORTED_SURFACES.
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:foobar:foobar\" chat_id=\"C999\" message_id=\"M000\" />\nhi"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"prose only"}]}}
JSONL
}

# ──────────────────────────────────────────────────────────────────────
# Multi-surface coverage (issue #20739 codex r2): SUPPORTED_SURFACES is
# {discord, telegram, teams}; _parse_source handles all three via the
# same plugin:<x>:<y> shape. Add telegram + teams production-format
# fixtures so the membership gate is exercised beyond discord.
# ──────────────────────────────────────────────────────────────────────

write_transcript_telegram_with_reply() {
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:telegram:telegram\" chat_id=\"T123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"sending"},{"type":"tool_use","name":"mcp__plugin_telegram_telegram__reply","input":{"chat_id":"T123","content":"hi back"}}]}}
JSONL
}

write_transcript_telegram_missing_reply() {
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:telegram:telegram\" chat_id=\"T123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"prose only, no reply tool"}]}}
JSONL
}

write_transcript_teams_with_reply() {
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:teams:teams\" chat_id=\"TM123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"sending"},{"type":"tool_use","name":"mcp__plugin_teams_teams__reply","input":{"chat_id":"TM123","content":"hi back"}}]}}
JSONL
}

write_transcript_teams_missing_reply() {
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:teams:teams\" chat_id=\"TM123\" message_id=\"M999\" />\nhello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"prose only, no reply tool"}]}}
JSONL
}

write_transcript_unparseable_prefix() {
  # 4 segments — _parse_source returns None.
  cat >"$1" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"<channel source=\"plugin:a:b:c\" chat_id=\"C999\" message_id=\"M000\" />\nhi"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"prose only"}]}}
JSONL
}

run_hook() {
  # $1: transcript path
  # $2: BRIDGE_AGENT_ID value (use empty string to unset)
  # $3: extra event JSON keys (e.g. ',"stop_hook_active":true'); may be empty
  local transcript="$1" agent_id="$2" extra="${3:-}"
  local event="{\"transcript_path\":\"$transcript\"$extra}"
  if [[ -z "$agent_id" ]]; then
    BRIDGE_AGENT_ID="" python3 "$HOOK" <<<"$event"
  else
    BRIDGE_AGENT_ID="$agent_id" python3 "$HOOK" <<<"$event"
  fi
}

# ---- Case (a) production format + matching mcp reply -> silent ----------
T="$TMP/a.jsonl"
write_transcript_with_reply "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (a) expected no output, got: $out"
pass "(a) plugin:discord:discord input + matching reply -> silent"

# ---- Case (b) production format + missing reply -> block ----------------
T="$TMP/b.jsonl"
write_transcript_missing_reply "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -n "$out" ]] || die "case (b) expected block JSON, got empty"
echo "$out" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
assert data.get("decision") == "block", data
reason = data.get("reason", "")
assert "plugin:discord:discord" in reason.lower(), "reason missing raw_source: " + reason
assert "C123" in reason, "reason missing chat_id: " + reason
assert "mcp__plugin_discord_discord__reply" in reason, "reason missing tool: " + reason
' || die "case (b) JSON shape mismatch"
pass "(b) plugin:discord:discord input + missing reply -> block (with discord_discord tool name)"

# ---- Case (c) production format + raw-source no-reply marker -> silent --
T="$TMP/c.jsonl"
write_transcript_no_reply_marker_raw "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (c) expected no output, got: $out"
pass "(c) plugin:discord:discord input + raw-source no-reply marker -> silent"

# ---- Case (c2) production format + short-surface no-reply marker -> silent ----
T="$TMP/c2.jsonl"
write_transcript_no_reply_marker_short "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (c2) expected no output, got: $out"
pass "(c2) plugin:discord:discord input + short-surface no-reply marker -> silent"

# ---- Case (d) TUI-source input (no channel tag) -> silent ---------------
T="$TMP/d.jsonl"
write_transcript_tui_only "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (d) expected no output, got: $out"
pass "(d) TUI-source input -> silent"

# ---- Case (e) BRIDGE_AGENT_ID empty -> silent ---------------------------
T="$TMP/e.jsonl"
write_transcript_missing_reply "$T"
out="$(run_hook "$T" "")"
[[ -z "$out" ]] || die "case (e) expected no output (BRIDGE_AGENT_ID empty), got: $out"
pass "(e) BRIDGE_AGENT_ID empty -> silent"

# ---- Case (f) stop_hook_active=true re-entry -> silent ------------------
T="$TMP/f.jsonl"
write_transcript_missing_reply "$T"
out="$(run_hook "$T" "agent-foo" ',"stop_hook_active":true')"
[[ -z "$out" ]] || die "case (f) expected no output (stop_hook_active=true), got: $out"
pass "(f) stop_hook_active re-entry -> silent"

# ---- Case (g) old reply for same chat_id does NOT satisfy newer unanswered ----
T="$TMP/g.jsonl"
write_transcript_old_reply_new_unanswered "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -n "$out" ]] || die "case (g) expected block JSON for new unanswered turn, got empty (old reply leaked through)"
echo "$out" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
assert data.get("decision") == "block"
reason = data.get("reason", "")
assert "M222" in reason, "reason should reference NEW message_id, got: " + reason
' || die "case (g) JSON shape mismatch (old reply may be satisfying new unanswered)"
pass "(g) old reply for same chat_id does not satisfy newer unanswered turn"

# ---- Case (h) legacy short form input + matching legacy reply -> silent ----
T="$TMP/h.jsonl"
write_transcript_legacy_with_reply "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (h) expected no output, got: $out"
pass "(h) legacy 'discord' source + mcp__plugin_discord__reply -> silent"

# ---- Case (h2) legacy short form input + missing reply -> block (with short tool name) ----
T="$TMP/h2.jsonl"
write_transcript_legacy_missing_reply "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -n "$out" ]] || die "case (h2) expected block JSON, got empty"
echo "$out" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
assert data.get("decision") == "block", data
reason = data.get("reason", "")
assert "mcp__plugin_discord__reply" in reason, "legacy expected tool: " + reason
' || die "case (h2) JSON shape mismatch (legacy expected tool)"
pass "(h2) legacy 'discord' source + missing reply -> block with short tool name"

# ---- Case (i) parseable plugin shape but unsupported surface -> silent ----
T="$TMP/i.jsonl"
write_transcript_unsupported_plugin "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (i) expected no output (surface=foobar not supported), got: $out"
pass "(i) plugin:foobar:foobar (unsupported surface) -> silent"

# ---- Case (j) unparseable plugin prefix -> silent -----------------------
T="$TMP/j.jsonl"
write_transcript_unparseable_prefix "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (j) expected no output (unparseable 4-segment prefix), got: $out"
pass "(j) plugin:a:b:c (4-segment) -> silent"

# ---- Case (k) telegram production format + matching reply -> silent -----
T="$TMP/k.jsonl"
write_transcript_telegram_with_reply "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (k) expected no output, got: $out"
pass "(k) plugin:telegram:telegram input + matching reply -> silent"

# ---- Case (k2) telegram production format + missing reply -> block ------
T="$TMP/k2.jsonl"
write_transcript_telegram_missing_reply "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -n "$out" ]] || die "case (k2) expected block JSON, got empty"
echo "$out" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
assert data.get("decision") == "block", data
reason = data.get("reason", "")
assert "plugin:telegram:telegram" in reason.lower(), "reason missing raw_source: " + reason
assert "T123" in reason, "reason missing chat_id: " + reason
assert "mcp__plugin_telegram_telegram__reply" in reason, "reason missing tool: " + reason
' || die "case (k2) JSON shape mismatch"
pass "(k2) plugin:telegram:telegram input + missing reply -> block (with telegram_telegram tool name)"

# ---- Case (l) teams production format + matching reply -> silent --------
T="$TMP/l.jsonl"
write_transcript_teams_with_reply "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -z "$out" ]] || die "case (l) expected no output, got: $out"
pass "(l) plugin:teams:teams input + matching reply -> silent"

# ---- Case (l2) teams production format + missing reply -> block ---------
T="$TMP/l2.jsonl"
write_transcript_teams_missing_reply "$T"
out="$(run_hook "$T" "agent-foo")"
[[ -n "$out" ]] || die "case (l2) expected block JSON, got empty"
echo "$out" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
assert data.get("decision") == "block", data
reason = data.get("reason", "")
assert "plugin:teams:teams" in reason.lower(), "reason missing raw_source: " + reason
assert "TM123" in reason, "reason missing chat_id: " + reason
assert "mcp__plugin_teams_teams__reply" in reason, "reason missing tool: " + reason
' || die "case (l2) JSON shape mismatch"
pass "(l2) plugin:teams:teams input + missing reply -> block (with teams_teams tool name)"

log "all cases passed"
