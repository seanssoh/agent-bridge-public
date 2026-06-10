#!/usr/bin/env bash
# scripts/smoke/1763-static-model-effort.sh — issue #1763 regression smoke.
#
# Bug: `agent update <a> --model <m> --effort <e>` (and `agent roster
# materialize-fields`) write BRIDGE_AGENT_MODEL / BRIDGE_AGENT_EFFORT to the
# roster and report success, but for a STATIC claude agent (source=static +
# non-empty BRIDGE_AGENT_LAUNCH_CMD) the values had ZERO effect on the
# launched `claude` process: the static launch builder
# (scripts/python-helpers/launch-cmd-static-claude-build.py, reached via
# lib/bridge-state.sh::bridge_build_static_claude_launch_cmd) read only the
# baked LAUNCH_CMD and never consulted the roster model/effort. Only the
# DYNAMIC builder emitted --model/--effort. Net: a silent no-op on the
# primary documented interface.
#
# Fix: the static builder now honors the roster model/effort with clear
# precedence, mirroring the dynamic builder's emission:
#   - roster value non-empty  -> the materialized value WINS: a stale baked
#     `--model`/`--effort` is stripped and the roster value re-emitted once.
#   - roster value empty       -> the baked LAUNCH_CMD `--model`/`--effort`
#     is preserved byte-for-byte (the documented `--set-launch-cmd`
#     workaround must keep working).
#
# Cases:
#   T1 (roster set, no baked flags): set model+effort, baked LAUNCH_CMD has
#      neither -> rendered command contains `--model m --effort e` exactly
#      once.
#   T2 (roster empty, baked flags): no roster model/effort, baked LAUNCH_CMD
#      carries `--model`/`--effort` -> baked flags preserved byte-for-byte.
#   T3 (roster set, DIFFERENT baked flags): roster value wins, single
#      emission, no duplicate `--model`/`--effort`, stale baked value gone.
#   T4 (resume-mode handling unchanged): --continue / --resume / --name /
#      --dangerously-skip-permissions emit in the same order as the existing
#      builder, with the roster flags appended after --name (no reordering
#      regression vs the #835 builder contract).
#
# Caller-source not relevant here — we drive the production builder directly
# through a tracked driver (footgun #11: no heredoc-stdin; the multi-line
# driver body lives in 1763-static-model-effort-helpers/).

# Bash 4+ re-exec (mirrors scripts/smoke/835-static-admin-launch.sh).
_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:1763-static-model-effort] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="1763-static-model-effort"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HELPERS_DIR="$SCRIPT_DIR/1763-static-model-effort-helpers"
DRIVER="$HELPERS_DIR/build-static-launch-driver.sh"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Render the static launch command for a synthesized agent through the
# production builder. Echoes the rendered LAUNCH_CMD on stdout.
render_static_launch() {
  local agent_id="$1"
  local continue_mode="$2"
  local launch_cmd="$3"
  local model="$4"
  local effort="$5"
  local output rc=0

  output="$("$BASH" "$DRIVER" \
    "$SMOKE_REPO_ROOT" "$BRIDGE_HOME" "$agent_id" "$continue_mode" \
    "$launch_cmd" "$model" "$effort" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    smoke_fail "driver exited rc=$rc for agent=$agent_id. Output: $output"
  fi
  local rendered
  rendered="$(smoke_shell_field LAUNCH_CMD "$output")"
  if [[ -z "$rendered" ]]; then
    smoke_fail "driver did not emit LAUNCH_CMD line for agent=$agent_id. Output: $output"
  fi
  printf '%s' "$rendered"
}

# Count occurrences of a literal flag token in a rendered command.
count_flag() {
  local haystack="$1"
  local flag="$2"
  # Word-boundary count via grep -o on space-delimited tokens.
  printf '%s\n' "$haystack" | tr ' ' '\n' | grep -cx -- "$flag" || true
}

test_roster_set_no_baked_flags() {
  local rendered
  rendered="$(render_static_launch t1 0 "claude --dangerously-skip-permissions" "claude-opus-4-8" "xhigh")"

  smoke_assert_contains "$rendered" "--model claude-opus-4-8" "T1: roster model injected"
  smoke_assert_contains "$rendered" "--effort xhigh" "T1: roster effort injected"
  smoke_assert_eq "1" "$(count_flag "$rendered" --model)" "T1: exactly one --model"
  smoke_assert_eq "1" "$(count_flag "$rendered" --effort)" "T1: exactly one --effort"
  smoke_assert_contains "$rendered" "--dangerously-skip-permissions" "T1: skip-permissions preserved"
  smoke_assert_contains "$rendered" "--name t1" "T1: --name preserved"
}

test_roster_empty_baked_flags_preserved() {
  local baked="claude --dangerously-skip-permissions --model claude-sonnet-4-5 --effort high"
  local rendered
  rendered="$(render_static_launch t2 0 "$baked" "" "")"

  # Roster empty -> the baked --model/--effort survive byte-for-byte (the
  # documented --set-launch-cmd workaround must not break).
  smoke_assert_contains "$rendered" "--model claude-sonnet-4-5" "T2: baked model preserved"
  smoke_assert_contains "$rendered" "--effort high" "T2: baked effort preserved"
  smoke_assert_eq "1" "$(count_flag "$rendered" --model)" "T2: exactly one --model (no double-emit)"
  smoke_assert_eq "1" "$(count_flag "$rendered" --effort)" "T2: exactly one --effort (no double-emit)"
}

test_roster_set_wins_over_different_baked() {
  local baked="claude --dangerously-skip-permissions --model claude-sonnet-4-5 --effort high"
  local rendered
  rendered="$(render_static_launch t3 0 "$baked" "claude-opus-4-8" "xhigh")"

  # Roster value WINS: the materialized model/effort are what `agent update`
  # semantically promised; the stale baked values are gone.
  smoke_assert_contains "$rendered" "--model claude-opus-4-8" "T3: roster model wins"
  smoke_assert_contains "$rendered" "--effort xhigh" "T3: roster effort wins"
  smoke_assert_not_contains "$rendered" "claude-sonnet-4-5" "T3: stale baked model dropped"
  smoke_assert_not_contains "$rendered" "--effort high" "T3: stale baked effort dropped"
  smoke_assert_eq "1" "$(count_flag "$rendered" --model)" "T3: single --model emission"
  smoke_assert_eq "1" "$(count_flag "$rendered" --effort)" "T3: single --effort emission"
}

test_resume_mode_handling_unchanged() {
  # continue_mode=1 with no resumable session -> the builder falls through to
  # the fresh-launch base (no --resume / --continue) because the hermetic
  # workdir has no transcript. The roster flags must still append cleanly
  # after --name with no reordering of the skip-permissions / --name tokens.
  local rendered
  rendered="$(render_static_launch t4 1 "claude --dangerously-skip-permissions --settings /tmp/x.json" "claude-opus-4-8" "xhigh")"

  # Canonical token order: claude ... --dangerously-skip-permissions --name t4
  # --model ... --effort ... <preserved extras>. Assert the prefix shape and
  # that the unrelated baked extra (--settings) is preserved (not dropped or
  # reordered ahead of the managed flags).
  smoke_assert_contains "$rendered" "--dangerously-skip-permissions --name t4 --model claude-opus-4-8 --effort xhigh" \
    "T4: managed flags emit in canonical order after --name"
  smoke_assert_contains "$rendered" "--settings /tmp/x.json" "T4: unrelated baked extra preserved"
  smoke_assert_eq "1" "$(count_flag "$rendered" --name)" "T4: exactly one --name"
  smoke_assert_eq "1" "$(count_flag "$rendered" --dangerously-skip-permissions)" "T4: exactly one --dangerously-skip-permissions"
}

test_joined_form_baked_flag_deduped() {
  # The `--set-launch-cmd` workaround may have authored the JOINED form
  # `--model=x` / `--effort=x` rather than the space-separated form. When the
  # roster overrides, the joined-form baked flag must still be stripped so the
  # render stays single-emission (no `--model=...` survivor alongside the
  # roster `--model ...`).
  local baked="claude --dangerously-skip-permissions --model=claude-sonnet-4-5 --effort=high"
  local rendered
  rendered="$(render_static_launch t5 0 "$baked" "claude-opus-4-8" "xhigh")"

  smoke_assert_contains "$rendered" "--model claude-opus-4-8" "T5: roster model wins over joined-form baked"
  smoke_assert_contains "$rendered" "--effort xhigh" "T5: roster effort wins over joined-form baked"
  smoke_assert_not_contains "$rendered" "claude-sonnet-4-5" "T5: stale joined-form baked model dropped"
  smoke_assert_not_contains "$rendered" "--effort=high" "T5: stale joined-form baked effort dropped"
  smoke_assert_not_contains "$rendered" "--model=" "T5: no joined-form --model= survivor"
  smoke_assert_eq "1" "$(count_flag "$rendered" --model)" "T5: single --model emission"
  smoke_assert_eq "1" "$(count_flag "$rendered" --effort)" "T5: single --effort emission"
}

test_override_preserves_option_shaped_follower() {
  # Codex r2 contract: when the roster overrides a SPACE-form baked `--model`/
  # `--effort` whose follower is OPTION-SHAPED (starts with `-`), the baked flag
  # is treated as malformed/valueless — drop ONLY the flag and PRESERVE the
  # follower. Consuming the follower (an earlier r1 over-correction) would eat an
  # unrelated flag and could strand its argument as a stray positional. A
  # `-`-prefixed follower like `-weird` is therefore kept, not dropped.
  local baked="claude --dangerously-skip-permissions --model -weird --effort -odd"
  local rendered
  rendered="$(render_static_launch t6 0 "$baked" "claude-opus-4-8" "xhigh")"

  smoke_assert_contains "$rendered" "--model claude-opus-4-8" "T6: roster model wins"
  smoke_assert_contains "$rendered" "--effort xhigh" "T6: roster effort wins"
  smoke_assert_contains "$rendered" "-weird" "T6: option-shaped follower of valueless --model preserved"
  smoke_assert_contains "$rendered" "-odd" "T6: option-shaped follower of valueless --effort preserved"
  smoke_assert_eq "1" "$(count_flag "$rendered" --model)" "T6: single --model emission"
  smoke_assert_eq "1" "$(count_flag "$rendered" --effort)" "T6: single --effort emission"
}

test_override_does_not_eat_following_unrelated_flag() {
  # Codex r2 repro (BLOCKING): a baked valueless `--model` immediately followed
  # by an UNRELATED flag with its own argument must not consume that flag as the
  # model "value", which would strand the argument as a stray positional. Here
  # `--model` is valueless and followed by `--settings /tmp/x.json`; the override
  # must drop only `--model`, leave `--settings /tmp/x.json` intact, and emit the
  # roster model/effort once.
  local baked="claude --dangerously-skip-permissions --model --settings /tmp/x.json --effort"
  local rendered
  rendered="$(render_static_launch t7 0 "$baked" "claude-opus-4-8" "xhigh")"

  smoke_assert_contains "$rendered" "--settings /tmp/x.json" "T7: unrelated --settings flag + arg preserved intact"
  smoke_assert_contains "$rendered" "--model claude-opus-4-8" "T7: roster model emitted"
  smoke_assert_contains "$rendered" "--effort xhigh" "T7: roster effort emitted"
  smoke_assert_eq "1" "$(count_flag "$rendered" --model)" "T7: single --model emission"
  smoke_assert_eq "1" "$(count_flag "$rendered" --effort)" "T7: single --effort emission"
  smoke_assert_eq "1" "$(count_flag "$rendered" --settings)" "T7: --settings not duplicated or dropped"
  # No stray positional: the historic bug consumed `--settings` as the model
  # value and stranded `/tmp/x.json` as a bare positional (`... --effort high
  # /tmp/x.json`). Assert `/tmp/x.json` is immediately preceded by `--settings`
  # (i.e. it is that flag's argument), never a standalone tail token.
  local prev_token
  prev_token="$(printf '%s\n' "$rendered" | tr ' ' '\n' | grep -B1 -x -- '/tmp/x.json' | head -n 1)"
  smoke_assert_eq "--settings" "$prev_token" "T7: /tmp/x.json stays the --settings argument, not a stray positional"
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd bash
  smoke_require_cmd grep
  smoke_require_cmd tr

  [[ -f "$DRIVER" ]] || smoke_fail "driver missing: $DRIVER"

  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "T1: roster model/effort injected when no baked flags"   test_roster_set_no_baked_flags
  smoke_run "T2: baked flags preserved when roster empty"            test_roster_empty_baked_flags_preserved
  smoke_run "T3: roster wins over different baked flags (single)"    test_roster_set_wins_over_different_baked
  smoke_run "T4: resume-mode + extras handling unchanged"            test_resume_mode_handling_unchanged
  smoke_run "T5: joined-form (--model=x) baked flag deduped on override" test_joined_form_baked_flag_deduped
  smoke_run "T6: valueless override preserves option-shaped follower" test_override_preserves_option_shaped_follower
  smoke_run "T7: valueless override does not eat unrelated flag"     test_override_does_not_eat_following_unrelated_flag

  smoke_log "passed"
}

main "$@"
