#!/usr/bin/env python3
"""audit-detail-json.py — build the `system_config_mutation` detail JSON
that `bridge_agent_update_emit_audit` writes to the audit log when the
agent CRUD subcommands (`agent update`, `agent delete`, future
`agent reclassify`) emit deny / dry-run / apply rows.

Invocation contract (positional, all required, all may be empty
strings):
    sys.argv[1]  = trigger_label (e.g. agent-update-apply,
                   agent-delete-apply, agent-delete-deny,
                   agent-delete-dry-run)
    sys.argv[2]  = actor (caller agent id or "operator")
    sys.argv[3]  = actor_source (operator-tui / operator-trusted-id /
                   unknown)
    sys.argv[4]  = target_agent
    sys.argv[5]  = roster path
    sys.argv[6]  = before_sha (sha256 of roster pre-mutation)
    sys.argv[7]  = after_sha  (sha256 post-mutation; empty for deny)
    sys.argv[8]  = operation (e.g. update / delete / reclassify)
    sys.argv[9]  = reason (deny reason; empty when apply)
    sys.argv[10] = before_launch_cmd
    sys.argv[11] = after_launch_cmd
    sys.argv[12] = before_channels
    sys.argv[13] = after_channels
    sys.argv[14] = actions_json (JSON array literal; empty/invalid is
                   coerced to [])
    sys.argv[15] = before_idle_timeout (issue #1093; optional, empty
                   when policy was unchanged or caller predates v0.14.5)
    sys.argv[16] = after_idle_timeout  (issue #1093; optional)
    sys.argv[17] = before_loop         (issue #1093; optional)
    sys.argv[18] = after_loop          (issue #1093; optional)
    sys.argv[19] = expressed_intent    (issue #1136; optional. One of
                   "always_on_yes" / "always_on_no" when the operator
                   passed `--always-on yes|no` (including legacy bare
                   `--always-on` on `agent add`, which is `yes`). Empty
                   when only a bare `--idle-timeout <N>` was passed —
                   the field is omitted from the audit detail in that
                   case. Recorded even on `changed=false` no-op
                   mutations so re-affirmation calls still produce a
                   searchable receipt.)

Output: a single JSON object on stdout, matching the wrapper-apply /
wrapper-deny detail shape that `bridge-config.py:cmd_set` writes for
config-set rows. This is the same shape `agent-bridge audit verify`
already accepts for agent-update.

Refs:
    - Footgun #11 / KNOWN_ISSUES.md §26: the body used to live as
      `python3 - … <<'PY' … PY` inside a `$()` capture in
      bridge_agent_update_emit_audit. Bash 5.3.9 `heredoc_write`
      deadlocked the moment any CRUD subcommand emitted an audit row,
      so the unregistered agent-update / agent-delete smokes never ran
      to completion on Bash 5.3.9 hosts. Standalone helper invoked
      file-as-argv keeps the path off the broken surface, same
      precedent as PR #940's registry/list/show extraction.
    - Issue #1023: launch commands routinely carry credential-bearing
      env values. This helper writes them into the audit-log detail
      (before/after launch_cmd + the recorded add-env actions), so it
      routes both through the shared launch-cmd-redact module before
      emission. The audit log keeps the SHA chain for tamper-evidence;
      it does not need the raw secret.
"""

import json
import os
import sys

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "scripts",
        "python-helpers",
    ),
)
import importlib  # noqa: E402

_redact = importlib.import_module("launch-cmd-redact")


def main() -> int:
    # 14 payload args (legacy) + 4 optional policy delta args (issue
    # #1093) + 1 optional expressed_intent arg (issue #1136) + script
    # name. Accept 15 / 19 / 20 argv to keep callers that predate each
    # extension working byte-identically.
    if len(sys.argv) not in (15, 19, 20):
        print(
            "usage: audit-detail-json.py "
            "<trigger> <actor> <actor_source> <target_agent> <path> "
            "<before_sha> <after_sha> <operation> <reason> "
            "<before_launch_cmd> <after_launch_cmd> "
            "<before_channels> <after_channels> <actions_json> "
            "[<before_idle_timeout> <after_idle_timeout> "
            "<before_loop> <after_loop> [<expressed_intent>]]",
            file=sys.stderr,
        )
        return 2

    # Issue #1093: accept the legacy 14-arg shape AND the extended 18-arg
    # shape. The trailing four positionals carry before/after deltas for
    # idle_timeout + loop. When absent (legacy callers), default to empty
    # strings and the new audit-detail fields are suppressed below.
    # Issue #1136: accept an optional 19th payload positional carrying
    # the operator-declared direction (`always_on_yes` / `always_on_no`).
    before_idle_timeout = ""
    after_idle_timeout = ""
    before_loop = ""
    after_loop = ""
    expressed_intent = ""
    if len(sys.argv) == 20:
        (
            trigger,
            actor,
            actor_source,
            target_agent,
            path,
            before_sha,
            after_sha,
            operation,
            reason,
            before_launch_cmd,
            after_launch_cmd,
            before_channels,
            after_channels,
            actions_json,
            before_idle_timeout,
            after_idle_timeout,
            before_loop,
            after_loop,
            expressed_intent,
        ) = sys.argv[1:]
    elif len(sys.argv) == 19:
        (
            trigger,
            actor,
            actor_source,
            target_agent,
            path,
            before_sha,
            after_sha,
            operation,
            reason,
            before_launch_cmd,
            after_launch_cmd,
            before_channels,
            after_channels,
            actions_json,
            before_idle_timeout,
            after_idle_timeout,
            before_loop,
            after_loop,
        ) = sys.argv[1:]
    else:
        (
            trigger,
            actor,
            actor_source,
            target_agent,
            path,
            before_sha,
            after_sha,
            operation,
            reason,
            before_launch_cmd,
            after_launch_cmd,
            before_channels,
            after_channels,
            actions_json,
        ) = sys.argv[1:]

    # Issue #1023: redact credential-bearing env values before they
    # land in the audit log. The redaction is value-only — env key
    # names stay visible — so audit readers still see which keys
    # changed.
    detail = {
        "kind": "system_config_mutation",
        "actor": actor,
        "actor_source": actor_source,
        "trigger": trigger,
        "path": path,
        "before_sha256": before_sha,
        "operation": operation,
        "matched_pattern": "agent-roster.local.sh",
        "target_agent": target_agent,
        "before_launch_cmd": _redact.redact_launch_cmd(before_launch_cmd),
        "after_launch_cmd": _redact.redact_launch_cmd(after_launch_cmd),
        "before_channels": before_channels,
        "after_channels": after_channels,
    }
    if after_sha:
        detail["after_sha256"] = after_sha
    if reason:
        detail["reason"] = reason
    try:
        actions = json.loads(actions_json) if actions_json else []
    except (TypeError, ValueError):
        actions = []
    detail["actions"] = _redact.redact_actions(actions)
    # Issue #1093: surface idle_timeout / loop deltas in the audit detail
    # when the caller supplied them AND a real change occurred (or at
    # least one side carries a value). Drop entirely-empty pairs so a
    # mutation that didn't touch policy stays byte-stable in the log.
    if before_idle_timeout or after_idle_timeout:
        detail["before_idle_timeout"] = before_idle_timeout
        detail["after_idle_timeout"] = after_idle_timeout
    if before_loop or after_loop:
        detail["before_loop"] = before_loop
        detail["after_loop"] = after_loop
    # Issue #1136: stamp the operator-declared direction when supplied.
    # Recorded even on `changed=false` no-op mutations (the audit emit
    # in run_update fires regardless of the changed bit, by design — a
    # re-affirmation call still gets a searchable receipt). Bare
    # `--idle-timeout <N>` invocations pass an empty string and the
    # field is omitted so audit-log readers can grep on the verb's
    # presence to find direction-declared events.
    if expressed_intent:
        detail["expressed_intent"] = expressed_intent

    print(json.dumps(detail, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
