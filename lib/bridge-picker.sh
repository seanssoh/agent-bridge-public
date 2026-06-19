#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/bridge-picker.sh — No-LLM picker auto-resolve stage (#1762).
#
# Layer 1 (detect) + Layer 2 (resolve) + Layer 3 (escalate) for the daemon
# tick. Replaces the continuous LLM sweeper: a fingerprint catalog
# (runtime-templates/shared/picker-catalog.json + an install-local override)
# resolves the frequent pickers in milliseconds for zero tokens; the LLM only
# ever sees a genuinely novel screen, via an escalation queue task to the
# admin, and the admin's picker-resolve skill appends a catalog entry so the
# next occurrence is script-resolved.
#
# CONTRACT (high-risk #1/#2):
#   - ALL tmux interaction goes through lib/bridge-tmux.sh primitives
#     (bridge_capture_recent for reads, bridge_tmux_send_picker_key /
#     bridge_tmux_send_submit_key for writes). This file issues NO raw
#     `tmux send-keys`.
#   - The structured work (catalog match, stuck-confirmation, anti-loop,
#     audit shaping) is delegated to lib/bridge-picker.py file-as-argv (no
#     heredoc-stdin — footgun #11).
#   - Every keystroke path is gated behind THREE safety rails:
#       (a) post-resolve verification — re-capture after keying and refuse to
#           re-key if the pane STILL matches any picker (primary defense vs an
#           approximate-regex mismatch);
#       (b) anti-loop counter — same (session, picker) resolved M times within
#           W seconds → stop + escalate;
#       (c) destructive-guard — never advance when the selected option matches
#           a destructive pattern (e.g. "Start a new conversation").
#   - Nothing here aborts the daemon main loop: every failure is best-effort.

# --------------------------------------------------------------------------
# Catalog path resolution
# --------------------------------------------------------------------------
# Shipped catalog (read-only): prefer the installed runtime copy, fall back to
# the source checkout template. Install-local overrides/additions live in a
# git-ignored file under the live shared dir.
bridge_picker_shipped_catalogs() {
  local found=0
  local runtime_copy="${BRIDGE_RUNTIME_SHARED_DIR:-}/picker-catalog.json"
  if [[ -n "${BRIDGE_RUNTIME_SHARED_DIR:-}" && -f "$runtime_copy" ]]; then
    printf '%s\n' "$runtime_copy"
    found=1
  fi
  local src_copy="${BRIDGE_SCRIPT_DIR:-}/runtime-templates/shared/picker-catalog.json"
  if [[ -n "${BRIDGE_SCRIPT_DIR:-}" && -f "$src_copy" && "$src_copy" != "$runtime_copy" ]]; then
    printf '%s\n' "$src_copy"
    found=1
  fi
  return $(( found == 1 ? 0 : 1 ))
}

bridge_picker_local_catalog() {
  printf '%s' "${BRIDGE_PICKER_LOCAL_CATALOG:-${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}/picker-catalog.local.json}"
}

bridge_picker_state_dir() {
  printf '%s' "${BRIDGE_PICKER_STATE_DIR:-${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}/picker}"
}

bridge_picker_snapshot_dir() {
  printf '%s' "${BRIDGE_PICKER_SNAPSHOT_DIR:-$(bridge_picker_state_dir)/snapshots}"
}

bridge_picker_audit_log() {
  printf '%s' "${BRIDGE_PICKER_AUDIT_LOG:-${BRIDGE_LOG_DIR:-$BRIDGE_HOME/logs}/picker-resolve.jsonl}"
}

# --------------------------------------------------------------------------
# Enable gate + python dispatch
# --------------------------------------------------------------------------
bridge_picker_enabled() {
  # Env override wins; otherwise the runtime config key. DEFAULT OFF: the
  # auto-resolve catalog ships with only [exact]/defer entries enabled and the
  # keystroke entries DISABLED, but the whole stage is opt-in until an install
  # turns it on, so a fresh install never auto-keys without operator intent.
  if [[ -n "${BRIDGE_PICKER_AUTORESOLVE:-}" ]]; then
    bridge_bool_is_true "$BRIDGE_PICKER_AUTORESOLVE"
    return $?
  fi
  bridge_config_bool_enabled "picker_autoresolve_enabled"
}

bridge_picker_py() {
  bridge_resolve_script_dir_check || return 1
  python3 "$BRIDGE_SCRIPT_DIR/lib/bridge-picker.py" "$@"
}

# Info log that prefers the daemon's structured logger when this module runs
# inside the daemon, and falls back to the lib-level logger otherwise (CLI /
# test contexts where daemon_info is not defined). bridge_warn is always
# available from bridge-core.sh, so warnings call it directly.
bridge_picker_log() {
  if declare -F daemon_info >/dev/null 2>&1; then
    daemon_info "$1"
  elif declare -F bridge_info >/dev/null 2>&1; then
    bridge_info "$1"
  fi
}

# Read a top-level field from a one-line JSON object emitted by the helper.
bridge_picker_json_field() {
  local json="$1"
  local key="$2"
  printf '%s' "$json" | python3 -c '
import json
import sys

try:
    obj = json.loads(sys.stdin.read() or "{}")
except ValueError:
    sys.exit(0)
val = obj.get(sys.argv[1])
if isinstance(val, bool):
    sys.stdout.write("true" if val else "false")
elif val is None:
    sys.stdout.write("")
elif isinstance(val, list):
    sys.stdout.write(" ".join(str(x) for x in val))
else:
    sys.stdout.write(str(val))
' "$key" 2>/dev/null || true
}

bridge_picker_append_audit() {
  # $1 = one-line JSON object. Append to the picker audit log; best-effort.
  local line="$1"
  [[ -n "$line" ]] || return 0
  local log
  log="$(bridge_picker_audit_log)"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  printf '%s\n' "$line" >>"$log" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Per-session resolve
# --------------------------------------------------------------------------
# Classify the live pane for one managed session; if a known picker is stuck,
# resolve it per policy with the three safety rails. Returns 0 if it took any
# action (resolved or escalated), 1 otherwise. Never aborts the caller.
bridge_picker_resolve_session() {
  local agent="$1"
  local session="$2"
  local engine="$3"

  [[ -n "$session" && -n "$engine" ]] || return 1
  bridge_tmux_session_exists "$session" || return 1
  # Cheap busy-skip: a session actively taking a turn / with pending composer
  # input is not stuck on a picker — skip the capture+classify entirely
  # (#1409 predicate). One capture per session per tick is the budget.
  if bridge_tmux_session_inject_busy "$session" "$engine" 2>/dev/null; then
    return 1
  fi

  local pane=""
  pane="$(bridge_capture_recent "$session" 40 2>/dev/null || true)"
  [[ -n "$pane" ]] || return 1

  local pane_file
  pane_file="$(mktemp -t bridge-picker-pane.XXXXXX 2>/dev/null)" || return 1
  printf '%s' "$pane" >"$pane_file" 2>/dev/null || { rm -f "$pane_file" 2>/dev/null; return 1; }

  local catalog_args=()
  local cat
  while IFS= read -r cat; do
    [[ -n "$cat" ]] && catalog_args+=(--catalog "$cat")
  done < <(bridge_picker_shipped_catalogs)
  local local_catalog
  local_catalog="$(bridge_picker_local_catalog)"
  if [[ -f "$local_catalog" ]]; then
    catalog_args+=(--local-catalog "$local_catalog")
  fi

  local decision=""
  decision="$(bridge_picker_py classify --engine "$engine" --pane-file "$pane_file" "${catalog_args[@]}" 2>/dev/null || true)"
  rm -f "$pane_file" 2>/dev/null || true
  [[ -n "$decision" ]] || return 1

  local matched picker_id policy pane_hash stuck_ticks
  matched="$(bridge_picker_json_field "$decision" matched)"
  if [[ "$matched" != "true" ]]; then
    # No catalog picker matched. Clear any stale KNOWN-picker stuck-state so a
    # later genuine known encounter starts fresh, then hand off to the unknown
    # path. A non_picker context signal (matched=false + non_picker=true) is a
    # HARD EXCLUSION — it must never count as unknown-stuck — and is filtered
    # inside bridge_picker_handle_unknown.
    bridge_picker_py clear-state --session "$session" --state-dir "$(bridge_picker_state_dir)" >/dev/null 2>&1 || true
    bridge_picker_handle_unknown "$agent" "$session" "$engine" "$pane" "$decision"
    return $?
  fi

  # A known picker matched → this is not a novel screen; drop any unknown-pane
  # tracking so a later genuine unknown starts fresh.
  bridge_picker_py clear-unknown --session "$session" --state-dir "$(bridge_picker_state_dir)" >/dev/null 2>&1 || true

  picker_id="$(bridge_picker_json_field "$decision" picker_id)"
  policy="$(bridge_picker_json_field "$decision" policy)"
  pane_hash="$(bridge_picker_json_field "$decision" pane_hash)"
  stuck_ticks="$(bridge_picker_json_field "$decision" stuck_confirm_ticks)"
  [[ "$stuck_ticks" =~ ^[0-9]+$ ]] || stuck_ticks=2

  # Stuck-confirmation: require N consecutive ticks with the same picker AND an
  # unchanged pane hash before acting (avoids racing a live redraw).
  local tick_out stuck
  tick_out="$(bridge_picker_py tick --session "$session" --engine "$engine" \
    --picker-id "$picker_id" --pane-hash "$pane_hash" \
    --stuck-confirm-ticks "$stuck_ticks" \
    --state-dir "$(bridge_picker_state_dir)" 2>/dev/null || true)"
  stuck="$(bridge_picker_json_field "$tick_out" stuck)"
  if [[ "$stuck" != "true" ]]; then
    return 1
  fi

  bridge_picker_log "picker detector: '${picker_id}' stuck on session=${session} (agent=${agent}, policy=${policy})"

  case "$policy" in
    defer)
      bridge_picker_handle_defer "$agent" "$session" "$engine" "$picker_id" "$decision"
      ;;
    auto_resolve)
      bridge_picker_handle_auto_resolve "$agent" "$session" "$engine" "$picker_id" "$pane" "$decision"
      ;;
    escalate)
      bridge_picker_escalate "$agent" "$session" "$engine" "$picker_id" "$pane" "$decision" "policy_escalate"
      ;;
    *)
      bridge_warn "picker resolver: unknown policy '${policy}' for '${picker_id}' on session=${session} — escalating"
      bridge_picker_escalate "$agent" "$session" "$engine" "$picker_id" "$pane" "$decision" "unknown_policy"
      ;;
  esac
}

# --------------------------------------------------------------------------
# Layer 3 — unknown (novel) screen path
# --------------------------------------------------------------------------
# Heuristic: does the captured tail look like an interactive prompt waiting on
# the agent (as opposed to ordinary scrolling output)? Conservative — a single
# positive signal is enough, but a pane with NO signal is treated as "not a
# prompt" so we never escalate plain working output. This only gates whether we
# track the pane as a candidate novel screen; the unknown-tick budget + the
# unchanged-hash requirement are what actually decide stuck.
bridge_picker_pane_looks_prompt_like() {
  local pane="$1"
  [[ -n "$pane" ]] || return 1
  # #1783: a bare selector glyph or box border is NO LONGER sufficient. Both
  # engines' NORMAL IDLE composer screens always contain '❯'/'›' and box edges
  # (╭╰│), so the old broad globs treated every idle session as a candidate
  # novel prompt — and because an idle pane is static, the unknown-tick tracker
  # escalated it as "stuck" ~5min after the stage came up (the #1783 fleet-wide
  # false-positive wave). Require an ACTUAL interactive affordance instead:
  #   - a selector glyph FOLLOWED BY option text (❯ / › / line-leading > + \S),
  #     which an empty idle composer ('❯' alone on its line) never satisfies;
  #   - a numbered option list line (e.g. "1. Yes", "  2) No");
  #   - an explicit [y/n]-style confirm token;
  #   - an explicit "Press <key>" / "Enter to …" / arrow-key affordance.
  # This only gates whether we START the unknown-tick timer; a positive here
  # still needs the pane UNCHANGED across the full minute/tick budget before any
  # escalation, which ordinary live output never satisfies. Known catalog
  # fingerprints are matched earlier and are unaffected by this heuristic.
  # Issue #815 / footgun #11: slurp the captured pane through a TEMPFILE +
  # `mapfile`, never a `done <<<"$pane"` here-string. This runs on EVERY idle
  # pane every daemon pass (hot path), and `<<<` can wedge on the Bash 5.3.9
  # heredoc_write deadlock — the same reason the lib/bridge-tmux.sh capture-walk
  # loops were staged through tempfiles. The tempfile is removed BEFORE the
  # scan loop, and there is NO RETURN trap — every return path (success and
  # failure) is already past cleanup, so the helper never leaves or clobbers a
  # caller's RETURN trap on its early-success paths (codex review #1783 P2).
  local _tmp _lines=()
  _tmp="$(mktemp)" || return 1
  printf '%s\n' "$pane" >"$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; return 1; }
  mapfile -t _lines <"$_tmp"
  rm -f -- "$_tmp"

  local line lower trimmed rest
  for line in "${_lines[@]}"; do
    # Whole-line confirm / affordance tokens. Lowercase the line once so the
    # affordance match is case-INSENSITIVE — a novel prompt's only signal may be
    # a lower-case 'press any key to continue' / 'hit any key to continue'
    # (codex review #1783 P2); the previous broad '*to continue*' glyph was
    # dropped in the tightening, so re-cover it case-insensitively here.
    lower="${line,,}"
    case "$lower" in
      *"[y/n]"*|*"(y/n)"*) return 0 ;;
      *"press enter"*|*"enter to "*|*"to continue"*|*"↑/↓"*|*"↑↓"*) return 0 ;;
      *"press "*"to "*|*"hit "*"to "*) return 0 ;;
    esac
    # Unicode selector glyph (❯/›) followed by real OPTION text — including when
    # the menu is wrapped in a box ('│ ❯ Option A   │'). Take everything after
    # the FIRST selector glyph, then strip whitespace AND trailing box-drawing
    # chars from both ends; a non-empty remainder is an option label. An EMPTY
    # idle composer renders the glyph alone (only spaces / a closing '│' follow),
    # so its remainder is empty and it is correctly NOT prompt-like.
    case "$line" in
      *❯*|*›*)
        rest="${line#*[❯›]}"
        # Strip leading/trailing whitespace and box-drawing glyphs. Cover the
        # light (│ ╮╯╭╰), heavy (┃), and ASCII (|) vertical borders so an empty
        # composer wrapped in ANY of them ('│ ❯ │' / '┃ ❯ ┃' / '| ❯ |') trims to
        # empty and is NOT mistaken for an option label (codex review #1783 P2).
        rest="${rest//│/ }"
        rest="${rest//┃/ }"
        rest="${rest//|/ }"
        rest="${rest//╮/ }"
        rest="${rest//╯/ }"
        rest="${rest//╭/ }"
        rest="${rest//╰/ }"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        rest="${rest%"${rest##*[![:space:]]}"}"
        [[ -n "$rest" ]] && return 0
        ;;
    esac
    # Strip leading whitespace once for the structured checks below.
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$trimmed" ]] || continue
    case "$trimmed" in
      # Line-leading ASCII '>' menu marker with option text ('> Continue').
      ">"[[:space:]]*[![:space:]]*)
        rest="${trimmed#>}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        [[ -n "$rest" ]] && return 0
        ;;
      # Numbered option list: a leading digit run then '.'/')' then a space and
      # text ('1. Yes', '2) No, keep current').
      [0-9]*)
        case "$trimmed" in
          [0-9]". "*[![:space:]]*|[0-9]") "*[![:space:]]*|\
          [0-9][0-9]". "*[![:space:]]*|[0-9][0-9]") "*[![:space:]]*) return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

# No catalog entry matched. If the pane is a genuine novel prompt-like screen
# that has stayed UNCHANGED past the unknown-stuck budget, escalate it to the
# admin with picker_id=unknown so the picker-resolve skill can classify it and
# extend the catalog. A non_picker context signal is a HARD EXCLUSION (it can
# never be unknown-stuck). Returns 0 if it escalated, 1 otherwise.
bridge_picker_handle_unknown() {
  local agent="$1" session="$2" engine="$3" pane="$4" decision="$5"

  # Hard exclusion: a matched non_picker banner is a known, non-blocking status
  # signal — never a novel stuck screen. Drop any unknown tracking and bail.
  local non_picker
  non_picker="$(bridge_picker_json_field "$decision" non_picker)"
  if [[ "$non_picker" == "true" ]]; then
    bridge_picker_py clear-unknown --session "$session" --state-dir "$(bridge_picker_state_dir)" >/dev/null 2>&1 || true
    return 1
  fi

  # Not prompt-like → ordinary output; reset the timer so a real prompt later
  # starts its budget fresh.
  if ! bridge_picker_pane_looks_prompt_like "$pane"; then
    bridge_picker_py clear-unknown --session "$session" --state-dir "$(bridge_picker_state_dir)" >/dev/null 2>&1 || true
    return 1
  fi

  local pane_hash unknown_minutes
  pane_hash="$(bridge_picker_json_field "$decision" pane_hash)"
  unknown_minutes="$(bridge_picker_json_field "$decision" unknown_stuck_minutes)"
  [[ "$unknown_minutes" =~ ^[0-9]+$ ]] || unknown_minutes=5

  # Track the unknown pane across ticks: escalate only when the SAME hash has
  # persisted across >= min-ticks consecutive ticks AND for the full minute
  # budget. A changing pane (agent making progress) resets the counter.
  local utick stuck
  utick="$(bridge_picker_py unknown-tick --session "$session" --pane-hash "$pane_hash" \
    --stuck-minutes "$unknown_minutes" --min-ticks 2 \
    --state-dir "$(bridge_picker_state_dir)" 2>/dev/null || true)"
  stuck="$(bridge_picker_json_field "$utick" stuck)"
  if [[ "$stuck" != "true" ]]; then
    return 1
  fi

  # Storm fuse (#1783): a per-pass global cap on UNKNOWN escalations, INDEPENDENT
  # of any fingerprint. The per-session anti-loop window does not apply to
  # escalations (they are not auto_resolve actions), so without this a heuristic
  # regression that mis-flags every idle session files N high-priority tasks per
  # pass. Over-cap sessions are counted into a single summarizing warn line
  # (emitted by bridge_picker_scan_all_sessions) instead of filing N×high tasks.
  #
  # Anti-starvation (codex review #1783 P2): an over-cap session's unknown timer
  # is deliberately LEFT INTACT (not cleared). The sessions that DID escalate
  # clear their own timer below and must re-elapse a fresh budget before they can
  # escalate again, while a suppressed session keeps its already-elapsed budget
  # and is immediately stuck on the next pass — so the stable BRIDGE_AGENT_IDS
  # scan order rotates which stuck sessions surface across passes instead of the
  # first `cap` agents monopolizing every cycle. The cap still bounds escalations
  # PER PASS; a genuinely-stuck screen is delayed, never starved.
  BRIDGE_PICKER_UNKNOWN_PASS_COUNT=$(( ${BRIDGE_PICKER_UNKNOWN_PASS_COUNT:-0} + 1 ))
  local cap
  cap="$(bridge_picker_unknown_escalation_cap)"
  if (( BRIDGE_PICKER_UNKNOWN_PASS_COUNT > cap )); then
    BRIDGE_PICKER_UNKNOWN_PASS_SUPPRESSED=$(( ${BRIDGE_PICKER_UNKNOWN_PASS_SUPPRESSED:-0} + 1 ))
    # Name only the first few suppressed agents in the eventual summary.
    if (( ${BRIDGE_PICKER_UNKNOWN_PASS_SUPPRESSED:-0} <= 5 )); then
      BRIDGE_PICKER_UNKNOWN_PASS_AGENTS="${BRIDGE_PICKER_UNKNOWN_PASS_AGENTS:-}${BRIDGE_PICKER_UNKNOWN_PASS_AGENTS:+, }${agent}"
    fi
    return 0
  fi

  bridge_picker_log "picker detector: UNKNOWN screen stuck on session=${session} (agent=${agent}) past ${unknown_minutes}m — escalating for classification"
  # Escalate with an empty picker_id; bridge_picker_escalate renders it as
  # 'unknown' and the body carries the captured pane for the admin to classify.
  bridge_picker_escalate "$agent" "$session" "$engine" "" "$pane" "$decision" "unknown_stuck"
  # Clear the unknown timer so we do not re-file every tick; the anti-loop
  # window inside the escalate path is not used here, so the timer reset is the
  # debounce — a fresh budget must elapse before the next escalation.
  bridge_picker_py clear-unknown --session "$session" --state-dir "$(bridge_picker_state_dir)" >/dev/null 2>&1 || true
  return 0
}

# Per-pass cap on UNKNOWN-stuck escalations (storm fuse, #1783). Env-tunable via
# BRIDGE_PICKER_UNKNOWN_ESCALATION_CAP; default 3 absorbs a fleet-wide regression
# while still letting a couple of genuinely-novel screens through each pass. A
# non-positive / non-numeric value falls back to the default.
bridge_picker_unknown_escalation_cap() {
  local cap="${BRIDGE_PICKER_UNKNOWN_ESCALATION_CAP:-3}"
  [[ "$cap" =~ ^[0-9]+$ ]] && (( cap >= 1 )) || cap=3
  printf '%s' "$cap"
}

# policy=defer → route to the EXISTING blocker machinery; do NOT key it here.
bridge_picker_handle_defer() {
  local agent="$1" session="$2" engine="$3" picker_id="$4" decision="$5"
  local defer_to
  defer_to="$(bridge_picker_json_field "$decision" defer_to)"

  # The Claude trust / resume-summary blockers are already handled by
  # recover_claude_bootstrap_blockers → bridge_tmux_prepare_claude_session.
  # Defer entries exist so the catalog DOCUMENTS those states without
  # competing with the existing handling. Best-effort nudge the existing
  # advancer (idempotent — it no-ops when the blocker has cleared).
  if [[ "$engine" == "claude" ]] && declare -F bridge_tmux_prepare_claude_session >/dev/null; then
    if bridge_tmux_prepare_claude_session "$session" 6 >/dev/null 2>&1; then
      bridge_picker_log "picker resolver: deferred '${picker_id}' on session=${session} to existing trust/summary machinery (${defer_to})"
    fi
  fi
  bridge_picker_audit_resolution "$agent" "$session" "$engine" "$picker_id" "defer" "$defer_to" "" "" "" "deferred"
  # The blocker advancer owns its own state; clear our stuck-tracking so we do
  # not re-defer every tick once it clears.
  bridge_picker_py clear-state --session "$session" --state-dir "$(bridge_picker_state_dir)" >/dev/null 2>&1 || true
}

# policy=auto_resolve → send the catalog key sequence, then verify.
bridge_picker_handle_auto_resolve() {
  local agent="$1" session="$2" engine="$3" picker_id="$4" pane_before="$5" decision="$6"

  # Issue #1991 single-sender: when the agentic resolver owns this agent, the
  # picker auto-resolve path must NOT key the pane (the resolver is the sole
  # sender). Report-only and return. No-op when the resolver is disabled.
  if declare -F bridge_prompt_resolver_owns_agent >/dev/null 2>&1 \
      && bridge_prompt_resolver_owns_agent "$agent"; then
    bridge_warn "picker resolver: agentic resolver (#1991) owns agent '${agent}' — auto-resolve report-only, no key sent on session=${session}"
    return 0
  fi

  local keys destructive
  keys="$(bridge_picker_json_field "$decision" keys)"
  destructive="$(bridge_picker_json_field "$decision" destructive_match)"

  # Rail (b): anti-loop. Record this resolution attempt FIRST; if the ceiling
  # is tripped, escalate instead of keying.
  local window max_resolves anti_out tripped
  window="$(bridge_picker_json_field "$decision" antiloop_window_seconds)"
  max_resolves="$(bridge_picker_json_field "$decision" antiloop_max_resolves)"
  [[ "$window" =~ ^[0-9]+$ ]] || window=120
  [[ "$max_resolves" =~ ^[0-9]+$ ]] || max_resolves=3
  anti_out="$(bridge_picker_py antiloop --session "$session" --picker-id "$picker_id" \
    --window-seconds "$window" --max-resolves "$max_resolves" \
    --state-dir "$(bridge_picker_state_dir)" 2>/dev/null || true)"
  tripped="$(bridge_picker_json_field "$anti_out" tripped)"
  if [[ "$tripped" == "true" ]]; then
    bridge_warn "picker resolver: anti-loop tripped for '${picker_id}' on session=${session} (>=${max_resolves} resolves in ${window}s) — escalating"
    bridge_picker_escalate "$agent" "$session" "$engine" "$picker_id" "$pane_before" "$decision" "antiloop_tripped"
    return 0
  fi

  # Rail (c): destructive-guard. If the live pane shows the destructive option
  # as the currently-selected line, refuse to advance and escalate. The catalog
  # encodes destructive_match (e.g. "Start a new conversation"); selection is
  # signaled by the ❯/›/> highlight glyph or reverse-video — we conservatively
  # check whether the destructive text sits on a glyph-marked line.
  if [[ -n "$destructive" ]] && bridge_picker_selected_is_destructive "$pane_before" "$destructive"; then
    bridge_warn "picker resolver: destructive option selected for '${picker_id}' on session=${session} — refusing to advance, escalating"
    bridge_picker_escalate "$agent" "$session" "$engine" "$picker_id" "$pane_before" "$decision" "destructive_selected"
    return 0
  fi

  # Snapshot the pre-resolution pane for the audit trail.
  local snap_before
  snap_before="$(bridge_picker_write_snapshot "$session" "$picker_id" before "$pane_before")"

  # Send the key sequence through the tmux primitive layer ONLY.
  local key sent_keys=""
  for key in $keys; do
    bridge_tmux_send_picker_key "picker_resolve_${picker_id}_${key}" "$session" "$engine" "$key" || true
    sent_keys="${sent_keys}${sent_keys:+ }${key}"
  done

  # Rail (a): post-resolve verification. Re-capture and re-classify; if the
  # pane STILL matches ANY picker fingerprint, do NOT re-key — escalate. This
  # is the primary defense against an approximate-regex mismatch keying the
  # wrong control.
  # Small settle so the TUI can redraw before we re-read.
  bridge_picker_settle
  # FAIL-OPEN default: the keys are ALREADY sent, so the verify outcome must be
  # initialized to a non-confirmed value. If the re-capture, mktemp, or classify
  # below cannot run (empty after-capture, mktemp failure, helper error), the
  # outcome stays `indeterminate` and we ESCALATE rather than reporting
  # verify-ok, re-keying, or crashing under `set -u` on an unbound variable.
  # Outcomes: confirmed_clear (pane verified no longer a picker — resolution ok)
  #           still_picker     (pane still matches a fingerprint — escalate)
  #           indeterminate    (verification could not be confirmed — escalate)
  local verify_state="indeterminate"
  local pane_after verify_decision still_matched
  pane_after="$(bridge_capture_recent "$session" 40 2>/dev/null || true)"
  local snap_after
  snap_after="$(bridge_picker_write_snapshot "$session" "$picker_id" after "$pane_after")"

  if [[ -n "$pane_after" ]]; then
    local pane_after_file
    pane_after_file="$(mktemp -t bridge-picker-after.XXXXXX 2>/dev/null || true)"
    if [[ -n "$pane_after_file" ]]; then
      printf '%s' "$pane_after" >"$pane_after_file" 2>/dev/null || true
      local catalog_args=()
      local cat
      while IFS= read -r cat; do
        [[ -n "$cat" ]] && catalog_args+=(--catalog "$cat")
      done < <(bridge_picker_shipped_catalogs)
      local local_catalog
      local_catalog="$(bridge_picker_local_catalog)"
      [[ -f "$local_catalog" ]] && catalog_args+=(--local-catalog "$local_catalog")
      verify_decision="$(bridge_picker_py classify --engine "$engine" --pane-file "$pane_after_file" "${catalog_args[@]}" 2>/dev/null || true)"
      rm -f "$pane_after_file" 2>/dev/null || true
      if [[ -n "$verify_decision" ]]; then
        still_matched="$(bridge_picker_json_field "$verify_decision" matched)"
        # A definitive classify result resolves the outcome: a fingerprint
        # match → still_picker; a clean classify → confirmed_clear. Anything
        # else (empty/garbled helper output) leaves verify_state=indeterminate.
        if [[ "$still_matched" == "true" ]]; then
          verify_state="still_picker"
        else
          verify_state="confirmed_clear"
        fi
      fi
    fi
  fi

  if [[ "$verify_state" == "still_picker" ]]; then
    bridge_warn "picker resolver: post-resolve verification FAILED for '${picker_id}' on session=${session} (pane still matches a picker) — not re-keying, escalating"
    bridge_picker_audit_resolution "$agent" "$session" "$engine" "$picker_id" "auto_resolve" "" "$sent_keys" "$snap_before" "$snap_after" "verify_failed"
    bridge_picker_escalate "$agent" "$session" "$engine" "$picker_id" "$pane_after" "$decision" "post_resolve_verify_failed"
    return 0
  fi

  if [[ "$verify_state" != "confirmed_clear" ]]; then
    # Fail-open: re-capture/mktemp/classify did not confirm a clean pane. The
    # keys are already sent, so we MUST NOT re-key and MUST NOT claim success —
    # audit the indeterminate verify and escalate for a human/admin to confirm.
    bridge_warn "picker resolver: post-resolve verification INDETERMINATE for '${picker_id}' on session=${session} (could not re-capture/classify after keying) — escalating"
    bridge_picker_audit_resolution "$agent" "$session" "$engine" "$picker_id" "auto_resolve" "" "$sent_keys" "$snap_before" "$snap_after" "verify_indeterminate"
    bridge_picker_escalate "$agent" "$session" "$engine" "$picker_id" "$pane_after" "$decision" "post_resolve_verify_indeterminate"
    return 0
  fi

  bridge_picker_log "picker resolver: auto-resolved '${picker_id}' on session=${session} keys='${sent_keys}' (post-resolve verify ok)"
  bridge_picker_audit_resolution "$agent" "$session" "$engine" "$picker_id" "auto_resolve" "" "$sent_keys" "$snap_before" "$snap_after" "ok"
  # Resolved → clear stuck-tracking so a fresh encounter re-confirms.
  bridge_picker_py clear-state --session "$session" --state-dir "$(bridge_picker_state_dir)" >/dev/null 2>&1 || true
}

# True iff the destructive option text appears on a line that carries a
# selection/highlight glyph (❯ › >) — i.e. it is the option that a bare
# "confirm" would activate. Conservative: requires BOTH the glyph and the
# destructive text on the same logical line.
bridge_picker_selected_is_destructive() {
  local pane="$1"
  local destructive="$2"
  [[ -n "$destructive" ]] || return 1
  # destructive is a space-joined token list from the JSON array; treat the
  # whole thing as one phrase by matching it as a substring on a glyphed line.
  local phrase="$destructive"
  local line
  while IFS= read -r line; do
    case "$line" in
      # Unicode selection glyphs (anywhere on the line) OR a line-leading ASCII
      # '>' marker (optionally indented) — Claude/Codex TUIs render the
      # highlighted option either way. The ASCII form is anchored to the line
      # start (after optional whitespace) so a mid-line '>' (e.g. a quoted '>'
      # or a redirection-looking glyph in body text) does NOT count as a
      # selection marker.
      *❯*|*›*) ;;
      [[:space:]]*">"*|">"*)
        # Re-confirm the '>' is line-leading: strip leading whitespace and
        # require the first remaining char to be '>'. (The case globs above are
        # broad; this guards against a '>' that merely follows other text after
        # the leading whitespace.)
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" == ">"* ]] || continue
        ;;
      *) continue ;;
    esac
    if [[ "$line" == *"$phrase"* ]]; then
      return 0
    fi
  done <<<"$pane"
  return 1
}

# --------------------------------------------------------------------------
# Layer 3 — escalation to the admin
# --------------------------------------------------------------------------
bridge_picker_escalate() {
  local agent="$1" session="$2" engine="$3" picker_id="$4" pane="$5" decision="$6" reason="$7"

  local route
  route="$(bridge_picker_json_field "$decision" escalation_route)"

  local admin_agent=""
  if command -v bridge_admin_agent_id >/dev/null 2>&1; then
    admin_agent="$(bridge_admin_agent_id 2>/dev/null || true)"
  fi
  [[ -n "$admin_agent" ]] || admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"

  local snap
  snap="$(bridge_picker_write_snapshot "$session" "${picker_id:-unknown}" escalate "$pane")"
  bridge_picker_audit_resolution "$agent" "$session" "$engine" "${picker_id:-unknown}" "escalate" "$route" "" "$snap" "" "$reason"

  if [[ -z "$admin_agent" ]]; then
    bridge_warn "picker resolver: would escalate '${picker_id:-unknown}' on session=${session} (reason=${reason}) but no admin agent configured"
    return 0
  fi

  # Resolve bridge-task.sh. BRIDGE_PICKER_TASK_SCRIPT lets a test point this at
  # a recorder; production resolves it from the source dir.
  local task_script=""
  if [[ -n "${BRIDGE_PICKER_TASK_SCRIPT:-}" && -x "${BRIDGE_PICKER_TASK_SCRIPT}" ]]; then
    task_script="${BRIDGE_PICKER_TASK_SCRIPT}"
  elif [[ -n "${BRIDGE_SCRIPT_DIR:-}" && -x "${BRIDGE_SCRIPT_DIR}/bridge-task.sh" ]]; then
    task_script="${BRIDGE_SCRIPT_DIR}/bridge-task.sh"
  fi
  [[ -n "$task_script" ]] || { bridge_warn "picker resolver: bridge-task.sh not found; cannot escalate '${picker_id:-unknown}'"; return 0; }

  local title
  if [[ "$route" == "permission_approval" ]]; then
    title="[PERMISSION] picker '${picker_id}' needs approval on ${agent} (${session})"
  elif [[ -z "$picker_id" || "$picker_id" == "unknown" ]]; then
    title="[picker] UNKNOWN stuck screen on ${agent} (${session}) — classify + extend catalog"
  else
    title="[picker] '${picker_id}' needs operator on ${agent} (${session}) — ${reason}"
  fi

  local body_file
  body_file="$(mktemp -t bridge-picker-escalate.XXXXXX 2>/dev/null || true)"
  [[ -n "$body_file" ]] || return 0
  {
    printf 'The picker auto-resolve detector found a stuck screen it will NOT auto-key.\n\n'
    printf 'agent: %s\n' "$agent"
    printf 'session: %s\n' "$session"
    printf 'engine: %s\n' "$engine"
    printf 'picker_id: %s\n' "${picker_id:-unknown}"
    printf 'reason: %s\n' "$reason"
    [[ -n "$route" ]] && printf 'route: %s\n' "$route"
    [[ -n "$snap" ]] && printf 'pane_snapshot: %s\n' "$snap"
    printf 'ts: %s\n\n' "$(date -u +%FT%TZ 2>/dev/null || date)"
    if [[ "$route" == "permission_approval" ]]; then
      printf 'Action: route through the install permission-approval flow (patch-permission-approval skill / [PERMISSION] queue). Do NOT blanket auto-approve.\n'
    elif [[ "${picker_id:-unknown}" == "unknown" ]]; then
      printf 'Action: run the picker-resolve skill — classify this pane, resolve it via the documented submit path, then APPEND a fingerprint+policy entry to the catalog so the next occurrence is script-resolved. Capture goes to shared/picker-captures/<slug>-<date>.txt.\n'
    else
      printf 'Action: resolve this known picker manually per shared/picker-captures/INVENTORY.md; if the fingerprint is approximate, replace it with a verbatim capture in the catalog.\n'
    fi
    printf '\n--- captured pane (last ~40 lines) ---\n'
    printf '%s\n' "$pane"
    printf 'Source: lib/bridge-picker.sh bridge_picker_escalate (#1762).\n'
  } >"$body_file" 2>/dev/null || true

  bash "$task_script" create \
    --from daemon \
    --to "$admin_agent" \
    --priority high \
    --title "$title" \
    --body-file "$body_file" >/dev/null 2>&1 || true
  rm -f "$body_file" 2>/dev/null || true

  bridge_picker_log "picker resolver: escalated '${picker_id:-unknown}' on session=${session} to ${admin_agent} (reason=${reason})"
  # After escalation, clear stuck-tracking so we do not re-file every tick;
  # the anti-loop window separately prevents an escalation storm.
  bridge_picker_py clear-state --session "$session" --state-dir "$(bridge_picker_state_dir)" >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# Audit + snapshots
# --------------------------------------------------------------------------
bridge_picker_write_snapshot() {
  local session="$1" picker_id="$2" phase="$3" pane="$4"
  [[ -n "$pane" ]] || { printf ''; return 0; }
  local dir
  dir="$(bridge_picker_snapshot_dir)"
  mkdir -p "$dir" 2>/dev/null || { printf ''; return 0; }
  local safe_session safe_picker stamp path
  safe_session="$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')"
  safe_picker="$(printf '%s' "$picker_id" | tr -c 'A-Za-z0-9._-' '_')"
  stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
  path="$dir/${safe_session}.${safe_picker}.${phase}.${stamp}.txt"
  printf '%s\n' "$pane" >"$path" 2>/dev/null || { printf ''; return 0; }
  printf '%s' "$path"
}

bridge_picker_audit_resolution() {
  local agent="$1" session="$2" engine="$3" picker_id="$4" action="$5" \
    route_or_defer="$6" keys="$7" snap_before="$8" snap_after="$9" outcome="${10:-}"
  local line
  line="$(bridge_picker_py audit-line \
    --kw "event=picker_resolution" \
    --kw "agent=${agent}" \
    --kw "session=${session}" \
    --kw "engine=${engine}" \
    --kw "picker_id=${picker_id}" \
    --kw "action=${action}" \
    --kw "detail=${route_or_defer}" \
    --kw "keys=${keys}" \
    --kw "snapshot_before=${snap_before}" \
    --kw "snapshot_after=${snap_after}" \
    --kw "outcome=${outcome}" 2>/dev/null || true)"
  bridge_picker_append_audit "$line"
}

bridge_picker_settle() {
  # Short, bounded settle for the TUI redraw between key send and re-capture.
  local secs="${BRIDGE_PICKER_SETTLE_SECONDS:-0.4}"
  sleep "$secs" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Daemon-callable phase entry point
# --------------------------------------------------------------------------
# Iterate every managed session and run the per-session resolver. Cheap: one
# capture per session per tick, and busy sessions are skipped before the
# capture. Cadence-gated by the daemon (bridge_daemon_pass_due).
bridge_picker_scan_all_sessions() {
  bridge_picker_enabled || return 1

  # Reset the per-pass UNKNOWN-escalation storm-fuse counters (#1783). These are
  # plain globals (the per-session resolver runs in this same shell, not a
  # subshell) read+bumped inside bridge_picker_handle_unknown.
  BRIDGE_PICKER_UNKNOWN_PASS_COUNT=0
  BRIDGE_PICKER_UNKNOWN_PASS_SUPPRESSED=0
  BRIDGE_PICKER_UNKNOWN_PASS_AGENTS=""

  local agent="" session="" engine=""
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    engine="$(bridge_agent_engine "$agent" 2>/dev/null || true)"
    [[ "$engine" == "claude" || "$engine" == "codex" ]] || continue
    session="$(bridge_agent_session "$agent" 2>/dev/null || true)"
    [[ -n "$session" ]] || continue
    bridge_tmux_session_exists "$session" || continue
    bridge_picker_resolve_session "$agent" "$session" "$engine" || true
  done

  # Storm fuse summary (#1783): if the per-pass UNKNOWN-escalation cap tripped,
  # emit ONE warn line naming the suppressed count + first agents instead of the
  # N high-priority queue tasks that the over-cap sessions would otherwise file.
  if (( ${BRIDGE_PICKER_UNKNOWN_PASS_SUPPRESSED:-0} > 0 )); then
    local cap
    cap="$(bridge_picker_unknown_escalation_cap)"
    bridge_warn "picker resolver: UNKNOWN-escalation cap (${cap}/pass) tripped — suppressed ${BRIDGE_PICKER_UNKNOWN_PASS_SUPPRESSED} additional escalation(s) this pass (first: ${BRIDGE_PICKER_UNKNOWN_PASS_AGENTS:-?}). A fleet-wide unknown-stuck wave usually means a heuristic/catalog regression, not ${BRIDGE_PICKER_UNKNOWN_PASS_SUPPRESSED} genuinely-novel screens — investigate before raising BRIDGE_PICKER_UNKNOWN_ESCALATION_CAP."
  fi
  return 0
}
