#!/usr/bin/env bash
# bridge-resolver.sh — Issue #1991 agentic blocked-prompt resolver helper.
#
# The SINGLE authorized key sender in resolver canary mode. Invoked by the
# resolver owner (patch) after the #1992 safety-floor daemon ROUTES a stable
# blocked-prompt detection to it as a [RESOLVER] task. The daemon never calls
# this helper — it detects, routes, and (on its 90s deadline) escalates only.
#
# Subcommands:
#   attempt --key prompt:<kind>:<hash> [--owner <a>] [--dry-run]
#       Resolve ONE routed blocked-prompt key: verify owner, acquire the per-key
#       attempt latch (one-sender proof), re-capture the live pane, re-run the
#       #1992 detector, require the SAME prompt_kind/content_hash/session,
#       require the shipped closed policy to ALLOW the kind, then send ONLY the
#       policy's semantic key tokens via bridge_tmux_send_picker_key, settle,
#       re-detect, and mark the outcome. Never re-keys. Never sends raw tmux.
#   drain [--limit N] [--owner <a>] [--dry-run]
#       Resolve up to N routed keys (first_seen order) in one task turn — the
#       #879 batch shape, one key sequence per key, no second sender.
#   status [--key <k>] [--format text|shell]
#       Report routed/attempt state for a key (or all keys). Read-only.
#
# SECURITY: pane text is UNTRUSTED. This helper never sources/evals/interpolates
# pane text. The action (which key tokens) is chosen ONLY from the shipped
# policy by (prompt_kind, confidence). The token vocabulary is the closed set
# bridge_tmux_send_picker_key enforces; a policy row that names any other token
# is refused. The resolver authorizes ITS OWN process to send via
# BRIDGE_PROMPT_RESOLVER_SEND_AUTHORIZED=1 only AFTER it has latched the key.
#
# Footgun #11: no heredoc-stdin into a subprocess.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bridge-lib.sh
source "$SCRIPT_DIR/bridge-lib.sh"

resolver_log() { printf '[resolver] %s\n' "$*" >&2; }
resolver_die() { printf '[resolver][error] %s\n' "$*" >&2; exit 1; }

# Echo the path to the per-agent #1992 safety-floor state dir.
resolver_safety_floor_dir() {
  printf '%s/safety-floor' "${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}"
}

# Locate the resolver routing sibling file whose SAFETY_FLOOR_KEY matches $1.
# Echoes the file path; returns 1 if no live routed state matches the key. We
# read each file's KEY field only. These *.resolver.env files are daemon-
# authored (%q quoted), NOT pane text.
resolver_state_file_for_key() {
  local want_key="$1"
  local dir sf k
  dir="$(resolver_safety_floor_dir)"
  [[ -d "$dir" ]] || return 1
  for sf in "$dir"/*.resolver.env; do
    [[ -f "$sf" ]] || continue
    # SAFETY_FLOOR_KEY is written via printf %q by the daemon. Extract + unquote
    # by sourcing ONLY that one assignment in a subshell.
    k="$(awk -F= '/^SAFETY_FLOOR_KEY=/{print substr($0, index($0,"=")+1); exit}' "$sf")"
    # shellcheck disable=SC2086
    k="$(eval printf '%s' $k 2>/dev/null || printf '%s' "$k")"
    if [[ "$k" == "$want_key" ]]; then
      printf '%s' "$sf"
      return 0
    fi
  done
  return 1
}

# Read a single SAFETY_FLOOR_* field from a state file (daemon-authored, %q
# quoted). Echoes the unquoted value.
resolver_state_field() {
  local sf="$1" field="$2" raw
  raw="$(awk -F= -v f="^${field}=" '$0 ~ f {print substr($0, index($0,"=")+1); exit}' "$sf")"
  [[ -n "$raw" ]] || { printf '%s' ''; return 0; }
  # shellcheck disable=SC2086
  eval printf '%s' $raw 2>/dev/null || printf '%s' "$raw"
}

# Verify the caller is the configured resolver owner (operational fence, NOT a
# hostile-local-user security boundary). codex r1 finding 4: identity is proven
# ONLY by the AMBIENT $BRIDGE_AGENT_ID (the bridge-managed wrapper sets it to the
# agent actually running). A caller-supplied --owner is NOT accepted as proof —
# it must merely MATCH the ambient identity (so a passed --owner can never
# escalate). An empty $BRIDGE_AGENT_ID fails closed (no implicit owner default).
resolver_require_owner() {
  local explicit_owner="$1"
  local configured ambient
  configured="$(bridge_prompt_resolver_owner)"
  ambient="${BRIDGE_AGENT_ID:-}"
  # Fail closed: no ambient identity → cannot prove the caller is the owner.
  if [[ -z "$ambient" ]]; then
    resolver_die "no BRIDGE_AGENT_ID in the environment — cannot prove resolver-owner identity; refusing"
  fi
  if [[ "$ambient" != "$configured" ]]; then
    resolver_die "caller '$ambient' is not the configured resolver owner '$configured' — refusing"
  fi
  # If --owner was passed, it must agree with the ambient identity (never a way
  # to claim a different identity).
  if [[ -n "$explicit_owner" && "$explicit_owner" != "$ambient" ]]; then
    resolver_die "--owner '$explicit_owner' does not match the running identity '$ambient' — refusing"
  fi
}

# Resolve the shipped policy decision for (prompt_kind, confidence). Echoes a
# tab-separated line: "<decision>\t<space-separated key tokens>". decision is
# allow|deny. Local policy may only DEMOTE (deny-wins). All pane text is
# excluded — this only looks at the typed kind + confidence.
resolver_policy_decision() {
  local prompt_kind="$1" confidence="$2"
  local shipped local_override
  shipped="$(bridge_prompt_resolver_shipped_policy)" || { printf 'deny\t'; return 0; }
  local_override="$(bridge_prompt_resolver_local_policy)"
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-resolver-policy.py" decide \
    --shipped "$shipped" \
    --local "$local_override" \
    --prompt-kind "$prompt_kind" \
    --confidence "$confidence"
}

# Re-capture + re-detect the live pane for a session. Echoes shell-format
# detect-prompt output (PROMPT_MATCHED / PROMPT_KIND / PROMPT_CONTENT_HASH ...).
resolver_capture_and_detect() {
  local session="$1"
  local capture
  capture="$(bridge_capture_recent "$session" "${BRIDGE_BLOCKED_PROMPT_CAPTURE_LINES:-120}" join 2>/dev/null || true)"
  [[ -n "$capture" ]] || return 1
  printf '%s\n' "$capture" | python3 "$SCRIPT_DIR/bridge-stall.py" detect-prompt --format shell 2>/dev/null
}

# --------------------------------------------------------------------------
# attempt
# --------------------------------------------------------------------------
resolver_attempt() {
  local key="" owner="" dry_run="${BRIDGE_PROMPT_RESOLVER_DRY_RUN:-0}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key) key="$2"; shift 2 ;;
      --owner) owner="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) resolver_die "attempt: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$key" ]] || resolver_die "attempt: --key required"
  resolver_require_owner "$owner"

  # 1. Load the #1992 routed state for the key.
  local sf
  if ! sf="$(resolver_state_file_for_key "$key")"; then
    resolver_log "attempt: no live routed state for key=$key (cleared/stale) — no send"
    printf 'outcome=no_routed_state key=%s\n' "$key"
    return 0
  fi
  local agent session prompt_kind content_hash confidence routed_owner routed_ts first_seen_ts
  agent="$(resolver_state_field "$sf" SAFETY_FLOOR_RESOLVER_AGENT)"
  [[ -n "$agent" ]] || agent="$(basename "$sf" .resolver.env)"
  session="$(resolver_state_field "$sf" SAFETY_FLOOR_SESSION_ID)"
  prompt_kind="$(resolver_state_field "$sf" SAFETY_FLOOR_PROMPT_KIND)"
  content_hash="$(resolver_state_field "$sf" SAFETY_FLOOR_CONTENT_HASH)"
  confidence="$(resolver_state_field "$sf" SAFETY_FLOOR_RESOLVER_CONFIDENCE)"
  routed_owner="$(resolver_state_field "$sf" SAFETY_FLOOR_RESOLVER_OWNER)"
  routed_ts="$(resolver_state_field "$sf" SAFETY_FLOOR_RESOLVER_ROUTED_TS)"
  first_seen_ts="$(resolver_state_field "$sf" SAFETY_FLOOR_FIRST_SEEN_TS)"
  [[ "$routed_ts" =~ ^[0-9]+$ ]] || routed_ts=0
  [[ "$first_seen_ts" =~ ^[0-9]+$ ]] || first_seen_ts=0

  # codex r1 finding 4: the routed state's owner must match the running identity.
  # The daemon wrote SAFETY_FLOOR_RESOLVER_OWNER when it routed; a caller whose
  # ambient identity is not that owner cannot drive this key's send.
  if [[ -n "$routed_owner" && "$routed_owner" != "${BRIDGE_AGENT_ID:-}" ]]; then
    resolver_die "routed owner '$routed_owner' != running identity '${BRIDGE_AGENT_ID:-}' for key=$key — refusing"
  fi

  # codex r1 finding 3: enforce the resolver attempt window in the helper. After
  # the absolute stop (first_seen + WINDOW_STOP) the #1992 floor owns escalation;
  # do NOT key a pane the floor is about to escalate. Prefer routed_ts + the
  # relative window when present, capped by the absolute first_seen stop.
  local now_ts; now_ts="$(date +%s)"
  local rel_window="${BRIDGE_PROMPT_RESOLVER_ATTEMPT_WINDOW_SECONDS:-45}"
  local abs_stop="${BRIDGE_PROMPT_RESOLVER_ROUTE_STOP_SECONDS:-75}"
  [[ "$rel_window" =~ ^[0-9]+$ ]] || rel_window=45
  [[ "$abs_stop" =~ ^[0-9]+$ ]] || abs_stop=75
  if (( routed_ts > 0 && now_ts - routed_ts >= rel_window )) \
     || (( first_seen_ts > 0 && now_ts - first_seen_ts >= abs_stop )); then
    resolver_log "attempt: resolver window elapsed for key=$key (routed_ts=$routed_ts first_seen=$first_seen_ts) — no send, #1992 floor escalates"
    printf 'outcome=window_elapsed key=%s\n' "$key"
    return 0
  fi

  # 2. Per-key attempt latch (one-sender proof). Refuse a 2nd send.
  if bridge_prompt_resolver_latch_held "$key"; then
    resolver_log "attempt: latch already held for key=$key — refusing a second send"
    printf 'outcome=latch_held_no_resend key=%s\n' "$key"
    return 0
  fi
  if ! bridge_prompt_resolver_acquire_latch "$key"; then
    resolver_log "attempt: could not acquire latch for key=$key (concurrent) — no send"
    printf 'outcome=latch_contended_no_send key=%s\n' "$key"
    return 0
  fi
  bridge_prompt_resolver_record_attempt "$key" "$agent" "$session" "$prompt_kind" "$content_hash"

  # 3. Re-capture + re-detect the live pane.
  local detect_shell
  if ! detect_shell="$(resolver_capture_and_detect "$session")" || [[ -z "$detect_shell" ]]; then
    resolver_log "attempt: pane re-capture/detect failed for session=$session — no send"
    bridge_prompt_resolver_mark_outcome "$key" verify_indeterminate
    printf 'outcome=verify_indeterminate key=%s\n' "$key"
    return 0
  fi
  local PROMPT_MATCHED=0 PROMPT_KIND="" PROMPT_CONFIDENCE="" PROMPT_CONTENT_HASH=""
  # detect_shell is bridge-stall.py output (PROMPT_*=json-quoted), not pane text.
  eval "$(printf '%s\n' "$detect_shell" | grep -E '^PROMPT_(MATCHED|KIND|CONFIDENCE|CONTENT_HASH)=')"

  # 4. Require the SAME prompt_kind + content_hash (and the session is unchanged
  #    by construction — we recaptured the routed session).
  if [[ "$PROMPT_MATCHED" != "1" ]]; then
    resolver_log "attempt: prompt cleared before send (key=$key) — no send"
    bridge_prompt_resolver_mark_outcome "$key" cleared_before_send
    printf 'outcome=cleared_before_send key=%s\n' "$key"
    return 0
  fi
  if [[ "$PROMPT_KIND" != "$prompt_kind" || "$PROMPT_CONTENT_HASH" != "$content_hash" ]]; then
    resolver_log "attempt: key drift (routed ${prompt_kind}/${content_hash}, live ${PROMPT_KIND}/${PROMPT_CONTENT_HASH}) — mismatch, no send"
    bridge_prompt_resolver_mark_outcome "$key" mismatch
    printf 'outcome=mismatch key=%s\n' "$key"
    return 0
  fi

  # 5. Require the shipped closed policy to ALLOW this kind+confidence.
  local decision keys
  IFS=$'\t' read -r decision keys < <(resolver_policy_decision "$PROMPT_KIND" "${PROMPT_CONFIDENCE:-$confidence}")
  if [[ "$decision" != "allow" ]]; then
    resolver_log "attempt: policy DENIES ${PROMPT_KIND} (confidence=${PROMPT_CONFIDENCE}) — no key sent, #1992 escalates"
    bridge_prompt_resolver_mark_outcome "$key" denied_policy
    bridge_audit_log "${owner:-$(bridge_prompt_resolver_owner)}" prompt_resolver_denied "$agent" \
      --detail prompt_kind="$PROMPT_KIND" --detail content_hash="$content_hash" 2>/dev/null || true
    printf 'outcome=denied_policy key=%s\n' "$key"
    return 0
  fi
  [[ -n "$keys" ]] || { bridge_prompt_resolver_mark_outcome "$key" denied_policy; printf 'outcome=denied_policy_no_keys key=%s\n' "$key"; return 0; }

  # Trust gating: the trust kind is allowed ONLY for a bridge-registered agent
  # session whose workdir matches the registered agent workdir.
  if [[ "$PROMPT_KIND" == "trust" ]]; then
    if ! resolver_trust_session_registered "$agent" "$session"; then
      resolver_log "attempt: trust prompt for unregistered/foreign-workdir session=$session — no send"
      bridge_prompt_resolver_mark_outcome "$key" denied_policy
      printf 'outcome=denied_policy_unregistered_trust key=%s\n' "$key"
      return 0
    fi
  fi

  # 6. Dry-run: record the would-act decision, send NO key.
  if bridge_bool_is_true "$dry_run"; then
    resolver_log "attempt: DRY-RUN would send tokens [$keys] for ${PROMPT_KIND} on session=$session"
    bridge_prompt_resolver_mark_outcome "$key" dry_run_would_send
    printf 'outcome=dry_run_would_send key=%s keys=%s\n' "$key" "$keys"
    return 0
  fi

  # 7. Send ONLY the policy's semantic tokens through the closed primitive.
  #    Authorize THIS process to send (latch is held), then revoke.
  local engine
  engine="$(bridge_agent_engine "$agent" 2>/dev/null || printf 'claude')"
  [[ -n "$engine" ]] || engine="claude"
  local token sent=""
  export BRIDGE_PROMPT_RESOLVER_SEND_AUTHORIZED=1
  for token in $keys; do
    bridge_tmux_send_picker_key "prompt_resolver_${PROMPT_KIND}_${token}" "$session" "$engine" "$token" || {
      resolver_log "attempt: send_picker_key refused token '$token' (closed vocab) — abort send"
      unset BRIDGE_PROMPT_RESOLVER_SEND_AUTHORIZED
      bridge_prompt_resolver_mark_outcome "$key" verify_indeterminate
      printf 'outcome=send_token_refused key=%s token=%s\n' "$key" "$token"
      return 0
    }
    sent="${sent}${sent:+ }${token}"
    sleep 0.3
  done
  unset BRIDGE_PROMPT_RESOLVER_SEND_AUTHORIZED

  # 8. Settle, re-capture, re-detect. Same key gone -> verified_clear.
  sleep "${BRIDGE_PROMPT_RESOLVER_SETTLE_SECONDS:-1}"
  local after_shell after_matched=0 after_kind="" after_hash=""
  if after_shell="$(resolver_capture_and_detect "$session")" && [[ -n "$after_shell" ]]; then
    local PROMPT_MATCHED=0 PROMPT_KIND="" PROMPT_CONTENT_HASH=""
    eval "$(printf '%s\n' "$after_shell" | grep -E '^PROMPT_(MATCHED|KIND|CONTENT_HASH)=')"
    after_matched="$PROMPT_MATCHED"; after_kind="$PROMPT_KIND"; after_hash="$PROMPT_CONTENT_HASH"
  else
    # Re-capture failed: cannot prove cleared. Never re-key.
    resolver_log "attempt: post-send re-capture failed — verify_indeterminate, NO second key"
    bridge_prompt_resolver_mark_outcome "$key" verify_indeterminate
    printf 'outcome=verify_indeterminate_after_send key=%s sent=%s\n' "$key" "$sent"
    return 0
  fi
  if [[ "$after_matched" != "1" || "$after_kind" != "$prompt_kind" || "$after_hash" != "$content_hash" ]]; then
    resolver_log "attempt: prompt cleared (sent [$sent]) — verified_clear"
    bridge_prompt_resolver_mark_outcome "$key" verified_clear
    bridge_audit_log "${owner:-$(bridge_prompt_resolver_owner)}" prompt_resolver_verified_clear "$agent" \
      --detail prompt_kind="$prompt_kind" --detail content_hash="$content_hash" --detail keys="$sent" 2>/dev/null || true
    printf 'outcome=verified_clear key=%s sent=%s\n' "$key" "$sent"
    return 0
  fi
  # Same key still present: do NOT re-key. #1992 escalates.
  resolver_log "attempt: same prompt still present after send [$sent] — still_prompt, NO second key (#1992 escalates)"
  bridge_prompt_resolver_mark_outcome "$key" still_prompt
  printf 'outcome=still_prompt key=%s sent=%s\n' "$key" "$sent"
  return 0
}

# Trust is allowed only when the target is a bridge-registered agent session AND
# the LIVE pane cwd equals the registered agent workdir (codex r1 finding 5).
# The live cwd is read from tmux METADATA (#{pane_current_path}) — NOT from pane
# text — so it is not attacker-controlled by the prompt content. Fails closed on
# any unknown (missing registration, missing/empty workdir, unreadable cwd, or a
# canonical mismatch).
resolver_trust_session_registered() {
  local agent="$1" session="$2"
  bridge_agent_exists "$agent" 2>/dev/null || return 1
  local registered_session registered_workdir
  registered_session="$(bridge_agent_session "$agent" 2>/dev/null || true)"
  [[ -n "$registered_session" && "$registered_session" == "$session" ]] || return 1
  registered_workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
  [[ -n "$registered_workdir" ]] || return 1

  # Read the live pane cwd from tmux metadata (not pane text).
  local pane_target live_cwd
  pane_target="$(bridge_tmux_pane_target "$session" 2>/dev/null || true)"
  [[ -n "$pane_target" ]] || return 1
  live_cwd="$(bridge_with_timeout 5 resolver_pane_cwd \
    tmux display-message -t "$pane_target" -p '#{pane_current_path}' 2>/dev/null || true)"
  [[ -n "$live_cwd" ]] || return 1

  # Canonical compare (resolve symlinks). FAIL CLOSED (codex r2 finding 5): if
  # EITHER path cannot be canonicalized (deleted / inaccessible dir), do NOT
  # fall back to a raw string compare — a raw-equal pair could differ after
  # symlink resolution. An uncanonicalizable path is treated as untrustworthy.
  local can_live can_reg
  can_live="$(cd -P -- "$live_cwd" 2>/dev/null && pwd -P)" || return 1
  can_reg="$(cd -P -- "$registered_workdir" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$can_live" && -n "$can_reg" ]] || return 1
  [[ "$can_live" == "$can_reg" ]] || return 1
  return 0
}

# --------------------------------------------------------------------------
# drain
# --------------------------------------------------------------------------
resolver_drain() {
  local limit=10 owner="" dry_run="${BRIDGE_PROMPT_RESOLVER_DRY_RUN:-0}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --owner) owner="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) resolver_die "drain: unknown arg '$1'" ;;
    esac
  done
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=10
  resolver_require_owner "$owner"

  # Collect routed keys ordered by first_seen_ts (FIFO fairness for the #879
  # batch). Each safety-floor state file with a SAFETY_FLOOR_RESOLVER_ROUTED_TS
  # is a routed key.
  local dir; dir="$(resolver_safety_floor_dir)"
  [[ -d "$dir" ]] || { resolver_log "drain: no routed keys"; printf 'drained=0\n'; return 0; }
  local sf first key routed
  local -a ordered=()
  for sf in "$dir"/*.resolver.env; do
    [[ -f "$sf" ]] || continue
    routed="$(resolver_state_field "$sf" SAFETY_FLOOR_RESOLVER_ROUTED_TS)"
    [[ -n "$routed" && "$routed" != "0" ]] || continue
    first="$(resolver_state_field "$sf" SAFETY_FLOOR_FIRST_SEEN_TS)"
    [[ "$first" =~ ^[0-9]+$ ]] || first=0
    key="$(resolver_state_field "$sf" SAFETY_FLOOR_KEY)"
    [[ -n "$key" ]] || continue
    ordered+=("${first}|${key}")
  done
  local count=0
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    (( count < limit )) || break
    key="${entry#*|}"
    if bridge_bool_is_true "$dry_run"; then
      resolver_attempt --key "$key" --owner "${owner:-$(bridge_prompt_resolver_owner)}" --dry-run || true
    else
      resolver_attempt --key "$key" --owner "${owner:-$(bridge_prompt_resolver_owner)}" || true
    fi
    count=$((count + 1))
  done < <(printf '%s\n' "${ordered[@]:-}" | sort -t'|' -k1,1n)
  resolver_log "drain: processed $count routed key(s) (limit=$limit)"
  printf 'drained=%s\n' "$count"
}

# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------
resolver_status() {
  local key="" format="text"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key) key="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      *) resolver_die "status: unknown arg '$1'" ;;
    esac
  done
  local dir; dir="$(resolver_safety_floor_dir)"
  local sf k routed outcome
  if [[ -d "$dir" ]]; then
    for sf in "$dir"/*.resolver.env; do
      [[ -f "$sf" ]] || continue
      k="$(resolver_state_field "$sf" SAFETY_FLOOR_KEY)"
      [[ -n "$k" ]] || continue
      [[ -z "$key" || "$k" == "$key" ]] || continue
      routed="$(resolver_state_field "$sf" SAFETY_FLOOR_RESOLVER_ROUTED_TS)"
      outcome="unstarted"
      local af; af="$(bridge_prompt_resolver_attempt_file "$k")"
      [[ -f "$af" ]] && outcome="$(awk -F= '/^RESOLVER_ATTEMPT_OUTCOME=/{print substr($0,index($0,"=")+1)}' "$af" | tail -1 | tr -d '"')"
      if [[ "$format" == "shell" ]]; then
        printf 'RESOLVER_KEY=%q\nRESOLVER_ROUTED_TS=%q\nRESOLVER_OUTCOME=%q\n' "$k" "${routed:-0}" "$outcome"
      else
        printf 'key=%s routed_ts=%s outcome=%s\n' "$k" "${routed:-0}" "$outcome"
      fi
    done
  fi
  return 0
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    attempt) shift; resolver_attempt "$@" ;;
    drain) shift; resolver_drain "$@" ;;
    status) shift; resolver_status "$@" ;;
    -h|--help|help|"")
      printf 'Usage: agent-bridge resolver <attempt|drain|status> [args]\n'
      printf '  attempt --key prompt:<kind>:<hash> [--owner <a>] [--dry-run]\n'
      printf '  drain [--limit N] [--owner <a>] [--dry-run]\n'
      printf '  status [--key <k>] [--format text|shell]\n'
      ;;
    *) resolver_die "unknown subcommand '$cmd' (attempt|drain|status)" ;;
  esac
}

main "$@"
