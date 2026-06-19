# shellcheck shell=bash
# lib/bridge-prompt-resolver.sh — Issue #1991 agentic blocked-prompt resolver.
#
# This module is the SHARED control plane for the canary-gated, patch-owned
# blocked-prompt resolver that sits on top of the #1992 safety floor. It is
# DEFAULT OFF (BRIDGE_PROMPT_RESOLVER_ENABLED=0).
#
# It owns four things, none of which send a key by itself:
#   1. The canary gate: is the resolver enabled, and is THIS agent in the
#      canary allowlist (single-sender mode active for it)?
#   2. The single-sender composition guard: when an agent is resolver-owned,
#      every LEGACY key sender (controller dev-channels watcher, agent
#      backstop, generic trust/summary auto-advance, picker auto-resolve,
#      picker-sweep cron + upgrade one-shot) must NOT send for it. The ONLY
#      authorized sender is the resolver helper, which sets
#      BRIDGE_PROMPT_RESOLVER_SEND_AUTHORIZED=1 in its own process AFTER it
#      acquires the per-key attempt latch.
#   3. The per-key attempt latch (mkdir-atomic): the ONE-SENDER proof. A second
#      send for the same (agent,session,prompt_kind,content_hash) key is refused
#      even with a duplicate routed task. Never stale-stolen inside the #1992
#      deadline — a crashed first attempt falls through to operator escalation,
#      not a second key.
#   4. Shipped policy resolution: read the source-controlled closed allow-list
#      (runtime-templates/shared/prompt-resolver-actions.json). Local files may
#      only DEMOTE to deny; they never promote a new auto-action.
#
# SECURITY INVARIANT (prompt injection): nothing in this module ever sources,
# evals, or interpolates pane text. Pane text influences only the deterministic
# classifier fields + hashes produced by bridge-stall.py detect-prompt. The
# action is selected ONLY from the shipped policy by (prompt_kind, confidence).

# --------------------------------------------------------------------------
# Canary flags
# --------------------------------------------------------------------------
# Master enable. DEFAULT 0 (off). When 0, every function here behaves as if no
# agent is resolver-owned, so the legacy senders run exactly as today.
bridge_prompt_resolver_enabled() {
  bridge_bool_is_true "${BRIDGE_PROMPT_RESOLVER_ENABLED:-0}"
}

# The single resolver owner agent (drains routed keys). Default: the admin
# agent, else literal `patch`.
bridge_prompt_resolver_owner() {
  printf '%s' "${BRIDGE_PROMPT_RESOLVER_OWNER:-${BRIDGE_ADMIN_AGENT_ID:-patch}}"
}

# Canary allowlist: BRIDGE_PROMPT_RESOLVER_AGENTS=<csv>|all. An agent is in the
# canary iff the resolver is enabled AND (the list is `all` OR the agent is a
# csv member). Empty list with enabled=1 means "enabled but no agents armed yet"
# (shadow phase) — no agent is owned, so legacy senders still run.
bridge_prompt_resolver_agent_in_canary() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  bridge_prompt_resolver_enabled || return 1
  local list="${BRIDGE_PROMPT_RESOLVER_AGENTS:-}"
  [[ -n "$list" ]] || return 1
  if [[ "$list" == "all" ]]; then
    return 0
  fi
  local IFS=','
  local item
  for item in $list; do
    # Trim surrounding whitespace from a csv element.
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ "$item" == "$agent" ]] && return 0
  done
  return 1
}

# True iff a LEGACY key sender must NOT send for this agent (resolver owns its
# blocked prompts). This is the single composition gate the four agent-aware
# senders call. It is independent of the per-process send-authorization flag:
# the resolver helper authorizes ITS OWN process via
# BRIDGE_PROMPT_RESOLVER_SEND_AUTHORIZED, not via this predicate.
bridge_prompt_resolver_owns_agent() {
  local agent="$1"
  bridge_prompt_resolver_agent_in_canary "$agent"
}

# Session-keyed variant for the low-level tmux primitive, which knows only the
# session (no agent in scope). Reverse-map session -> agent via the roster, then
# apply the agent gate. Best-effort: if the roster cannot resolve the session to
# an agent, this returns false (the primitive's caller is responsible for the
# authoritative agent-level gate; this is defense-in-depth only).
bridge_prompt_resolver_owns_session() {
  local session="$1"
  [[ -n "$session" ]] || return 1
  bridge_prompt_resolver_enabled || return 1
  local agent=""
  agent="$(bridge_prompt_resolver_agent_for_session "$session" 2>/dev/null || true)"
  [[ -n "$agent" ]] || return 1
  bridge_prompt_resolver_owns_agent "$agent"
}

# Reverse map a tmux session name to a roster agent id. Convention across the
# codebase is session-name == agent-name for static/admin agents; we confirm via
# the roster's agent->session map when available and fall back to the identity
# mapping (the picker-sweep / launch convention).
bridge_prompt_resolver_agent_for_session() {
  local session="$1"
  [[ -n "$session" ]] || return 1
  local agent=""
  if declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1; then
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ -n "$agent" ]] || continue
      if [[ "$(bridge_agent_session "$agent" 2>/dev/null || true)" == "$session" ]]; then
        printf '%s' "$agent"
        return 0
      fi
    done
  fi
  # Fallback: the session-name == agent-name convention.
  printf '%s' "$session"
  return 0
}

# The per-PROCESS send authorization. The resolver helper sets
# BRIDGE_PROMPT_RESOLVER_SEND_AUTHORIZED=1 in its OWN environment after it has
# acquired the per-key attempt latch. The central tmux guard lets a send through
# for a resolver-owned session ONLY when this is set. A legacy sender (which
# never sets it) is therefore refused for resolver-owned sessions.
bridge_prompt_resolver_send_authorized() {
  bridge_bool_is_true "${BRIDGE_PROMPT_RESOLVER_SEND_AUTHORIZED:-0}"
}

# CENTRAL defense-in-depth guard for the low-level send path. Returns 0 (block
# the send) when the resolver owns this session AND the current process is NOT
# the authorized resolver helper. Returns 1 (allow) otherwise. Dry-run also
# blocks the send. Callers: bridge_tmux_send_picker_key / advance-blocker.
bridge_prompt_resolver_should_block_send() {
  local session="$1"
  bridge_prompt_resolver_enabled || return 1
  bridge_prompt_resolver_owns_session "$session" || return 1
  # Resolver-owned session. Only the authorized resolver helper (latch held) may
  # send — and never in dry-run.
  if bridge_prompt_resolver_send_authorized && ! bridge_bool_is_true "${BRIDGE_PROMPT_RESOLVER_DRY_RUN:-0}"; then
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------
# Per-key attempt latch (the one-sender proof)
# --------------------------------------------------------------------------
bridge_prompt_resolver_state_dir() {
  printf '%s' "${BRIDGE_PROMPT_RESOLVER_STATE_DIR:-${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}/prompt-resolver}"
}

# Sanitize a resolver key (prompt:<kind>:<hash>) to a safe filename component.
# Defense-in-depth: keys are internal, but never let one produce a path
# traversal latch path.
bridge_prompt_resolver_safe_key() {
  local key="$1"
  printf '%s' "$key" | tr -c 'A-Za-z0-9._:-' '_' | tr ':' '_'
}

bridge_prompt_resolver_lock_dir() {
  local key="$1"
  printf '%s/locks/%s.lock' "$(bridge_prompt_resolver_state_dir)" "$(bridge_prompt_resolver_safe_key "$key")"
}

bridge_prompt_resolver_attempt_file() {
  local key="$1"
  printf '%s/attempts/%s.env' "$(bridge_prompt_resolver_state_dir)" "$(bridge_prompt_resolver_safe_key "$key")"
}

# Atomically acquire the per-key latch. Returns 0 if THIS call acquired it
# (mkdir succeeded), 1 if it already exists (a prior attempt latched it — refuse
# a second send). NEVER stale-steals.
bridge_prompt_resolver_acquire_latch() {
  local key="$1"
  local lock_dir
  lock_dir="$(bridge_prompt_resolver_lock_dir "$key")"
  mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || return 2
  if mkdir "$lock_dir" 2>/dev/null; then
    return 0
  fi
  return 1
}

# True iff a latch already exists for the key (a send was attempted).
bridge_prompt_resolver_latch_held() {
  local key="$1"
  [[ -d "$(bridge_prompt_resolver_lock_dir "$key")" ]]
}

# Record the attempt-start metadata (called by the helper AFTER acquiring the
# latch, BEFORE any key send). Atomic write of an env file.
bridge_prompt_resolver_record_attempt() {
  local key="$1"
  local agent="$2"
  local session="$3"
  local prompt_kind="$4"
  local content_hash="$5"
  local file tmp
  file="$(bridge_prompt_resolver_attempt_file "$key")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 1
  {
    printf 'RESOLVER_ATTEMPT_KEY=%q\n' "$key"
    printf 'RESOLVER_ATTEMPT_AGENT=%q\n' "$agent"
    printf 'RESOLVER_ATTEMPT_SESSION=%q\n' "$session"
    printf 'RESOLVER_ATTEMPT_PROMPT_KIND=%q\n' "$prompt_kind"
    printf 'RESOLVER_ATTEMPT_CONTENT_HASH=%q\n' "$content_hash"
    printf 'RESOLVER_ATTEMPT_STARTED_TS=%q\n' "$(date +%s)"
    printf 'RESOLVER_ATTEMPT_OUTCOME=%q\n' "started"
  } >"$tmp" 2>/dev/null && mv -f -- "$tmp" "$file" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
}

# Stamp the terminal outcome of an attempt (verified_clear / still_prompt /
# mismatch / denied_policy / verify_indeterminate). Best-effort append-update.
bridge_prompt_resolver_mark_outcome() {
  local key="$1"
  local outcome="$2"
  local file tmp
  file="$(bridge_prompt_resolver_attempt_file "$key")"
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 0
  {
    grep -v '^RESOLVER_ATTEMPT_OUTCOME=' "$file" 2>/dev/null || true
    printf 'RESOLVER_ATTEMPT_OUTCOME=%q\n' "$outcome"
    printf 'RESOLVER_ATTEMPT_OUTCOME_TS=%q\n' "$(date +%s)"
  } >"$tmp" 2>/dev/null && mv -f -- "$tmp" "$file" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 0; }
}

# --------------------------------------------------------------------------
# Shipped policy resolution
# --------------------------------------------------------------------------
# Echo the path to the SHIPPED (source-controlled) policy file. Prefer the
# installed runtime copy, fall back to the source-checkout template. NEVER a
# local override here (local files may only demote, handled by the python
# decision helper).
bridge_prompt_resolver_shipped_policy() {
  local runtime_copy="${BRIDGE_RUNTIME_SHARED_DIR:-}/prompt-resolver-actions.json"
  if [[ -n "${BRIDGE_RUNTIME_SHARED_DIR:-}" && -f "$runtime_copy" ]]; then
    printf '%s' "$runtime_copy"
    return 0
  fi
  local src_copy="${BRIDGE_SCRIPT_DIR:-}/runtime-templates/shared/prompt-resolver-actions.json"
  if [[ -n "${BRIDGE_SCRIPT_DIR:-}" && -f "$src_copy" ]]; then
    printf '%s' "$src_copy"
    return 0
  fi
  return 1
}

# Echo the install-local override path (git-ignored). May only DEMOTE rows.
bridge_prompt_resolver_local_policy() {
  printf '%s' "${BRIDGE_PROMPT_RESOLVER_LOCAL_POLICY:-${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}/prompt-resolver-actions.local.json}"
}
