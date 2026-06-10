---
name: picker-resolve
description: Use when a daemon-filed `[picker]` queue task arrives (an agent stuck on an interactive picker screen the no-LLM detector would not auto-key), or when wording like "stuck picker", "unknown picker", "classify this pane", "extend the picker catalog", or "picker auto-resolve escalation" shows up. Encodes the admin classify→resolve→extend-catalog loop for the #1762 picker auto-resolve feature: classify the captured pane, resolve it now via the documented engine-aware submit path, capture the verbatim pane string, then APPEND a fingerprint+policy entry to the picker catalog so the NEXT occurrence is script-resolved with zero tokens. The catalog grows from real encounters; the LLM cost converges to zero.
---

# picker-resolve — admin tail for the no-LLM picker auto-resolver

The daemon resolves the *known* frequent pickers (Codex update, Claude resume/compact, trust prompt) for free from a fingerprint catalog. It escalates to you (the install's admin) only when it sees something it will **not** auto-key:

- an **unknown** stuck screen (no fingerprint match), or
- a known picker on an **auth surface** (`codex-login-expired`, `claude-permission`) that is escalate-only by policy, or
- a known picker whose **post-resolve verification failed** / **anti-loop tripped** / **destructive option was selected**.

Your job: resolve the one in front of you now, AND make the next one script-resolvable.

## When this skill triggers

Primary: a queue task titled `[picker] ...` or `[PERMISSION] picker '...'` from `daemon`. The body carries `agent`, `session`, `engine`, `picker_id` (or `unknown`), `reason`, an optional `route`, a `pane_snapshot` path under `state/picker/snapshots/`, and the captured pane text inline.

Secondary: the operator asks you to classify a stuck pane or to grow the picker catalog.

Do **not** fire for `[PERMISSION]` tasks that route to `patch-permission-approval` — those go through that skill (the picker detector only *surfaces* the permission prompt; the approval decision is theirs). The picker detector never auto-approves a permission prompt.

## The loop: classify → resolve → extend

1. **Read the pane.** Use the inline pane text (or `cat` the `pane_snapshot` path). Identify which CLI (`engine`) and which control is on screen. Cross-reference `shared/picker-captures/INVENTORY.md` — the operator-maintained policy table (slug → correct default key → destructive-guard).

2. **Resolve it now**, via the documented submit path — never raw `tmux send-keys`:
   - Attach (`tmux attach -t =<session>`) and key it yourself, or
   - use the bridge's engine-aware submit primitive for the chosen option.
   - Honor the INVENTORY policy: pick the **non-destructive / continue-current** option. For `claude-resume-compact` that is *continue the existing session* ("그냥 시작"), never "start a new conversation". For `codex-update`, confirm the update and verify the session **resumes the same `session_id`** after restart. For auth surfaces (`codex-login-expired`, `claude-permission`) do **not** key blindly — complete the human auth round / route the approval.

3. **Capture the verbatim pane string.** Save `tmux capture-pane -p -t =<session> | tail -40` to `shared/picker-captures/<slug>-<YYYYMMDD>.txt` with a one-line "correct default" comment. This is the ground-truth string that replaces an approximate regex.

4. **Extend the catalog (the part that makes the LLM cost converge to zero).** Append (or correct) an entry in the install-local catalog
   `$BRIDGE_SHARED_DIR/picker-catalog.local.json` (git-ignored — machine-specific strings are fine there). Mirror the shipped schema in `runtime-templates/shared/picker-catalog.json`:

   ```json
   {
     "version": 1,
     "entries": [
       {
         "picker_id": "<slug>",
         "engine": "claude|codex|any",
         "enabled": true,
         "confidence": "exact",
         "comment": "verbatim from shared/picker-captures/<slug>-<date>.txt",
         "match": ["<regex grounded in the real capture>", "<second anchor>"],
         "destructive_match": ["<the wrong/destructive option text>"],
         "policy": "auto_resolve",
         "keys": ["select_first", "confirm"],
         "post_resolve_verify": true,
         "expect_restart": false
       }
     ]
   }
   ```

   - Use **at least two** `match` anchors so the fingerprint cannot false-positive against ordinary prose.
   - Set `confidence: "exact"` only when the regex is grounded in a real capture; until then leave the shipped `[approx]` entry **disabled**.
   - Keep `post_resolve_verify: true` for every keystroke policy — it is the primary defense against an approximate-regex mismatch.
   - For an auth/permission surface, set `policy: "escalate"` (and `escalation_route` for permission) — **never** add a `keys` field to those.
   - A local entry with the same `picker_id` as a shipped one **overrides** it (so you can promote an `[approx]` shipped entry by adding an enabled `[exact]` local one).

## Policy rails the daemon already enforces (don't fight them)

- **Post-resolve verification:** after keying, the daemon re-captures and refuses to re-key if the pane still matches any picker — it escalates to you instead. If you keep getting escalations for one picker, the fingerprint is wrong; fix the regex.
- **Anti-loop:** same `(session, picker)` resolved too many times in a short window → the daemon stops and escalates. If you see this, the keystrokes are not actually clearing the picker.
- **Destructive-guard:** the daemon refuses to advance when the selected option matches `destructive_match`. Encode the destructive option for every list picker.

## Enabling the stage on an install

The whole stage is opt-in. Turn it on with the runtime config key `picker_autoresolve_enabled: true` (or `BRIDGE_PICKER_AUTORESOLVE=1`). Per-picker behavior is controlled by each catalog entry's `enabled` flag; the escalation target is the configured admin agent (`BRIDGE_ADMIN_AGENT_ID`). Audit of every auto-resolution and escalation lands in `logs/picker-resolve.jsonl` with before/after pane snapshot paths under `state/picker/snapshots/`.
