"""Cron-followup frontmatter parser (PR2 of cron inbox-only reporting).

Consumed by parent-session helpers, status views, and routing diagnostics
that need to reason about the structured `[cron-followup]` inbox tasks
written by `bridge-cron-runner.write_followup_body` (PR1).

Stdlib-only by design — the runner is Python-stdlib (no PyYAML, no `eval`,
no third-party deps), so the consumer must be too. The frontmatter contract
is documented in ARCHITECTURE.md "Cron reporting contract" and in the body
of `bridge-cron-runner.write_followup_body`.

Body shape produced by the writer:

    ---
    { ...JSON... }
    ---

    # [cron-followup] <job-name>
    ...markdown...

The opening fence is exactly `---` on the first line, JSON spans through
the next exact `---`, then a blank line, then the markdown body.
"""

from __future__ import annotations

import json
from typing import Any

__all__ = ["parse_followup", "DELIVERY_INTENT_VALUES", "REPORTING_POLICY_VALUES"]

DELIVERY_INTENT_VALUES = ("silent", "main_session_only", "forward_to_user")
REPORTING_POLICY_VALUES = ("default", "always_main_session", "always_silent")
_FORWARD_TARGET_KEYS = ("channel", "target_ref", "format")
_FENCE = "---"
_SCHEMA_VERSION = 1


def parse_followup(body_text: str) -> dict[str, Any] | None:
    """Parse the strict JSON-frontmatter cron-followup body.

    Returns the frontmatter dict on success, or `None` if the body is
    malformed, the frontmatter is missing, the schema_version mismatches,
    or any required field is invalid. The caller decides what to do with
    a `None` return — typically: fall back to legacy prose handling or log
    and skip.
    """

    if not isinstance(body_text, str) or not body_text:
        return None

    # `splitlines()` handles `\n`, `\r\n`, and `\r` uniformly. The writer
    # emits `\n` only, but tolerating CRLF protects us from intermediaries
    # that re-encode the body (e.g. a queue mirror over a Windows path).
    lines = body_text.splitlines()
    if not lines or lines[0].strip() != _FENCE:
        return None

    closing_index = None
    for index in range(1, len(lines)):
        if lines[index].strip() == _FENCE:
            closing_index = index
            break
    if closing_index is None:
        return None

    json_blob = "\n".join(lines[1:closing_index]).strip()
    if not json_blob:
        return None

    try:
        frontmatter = json.loads(json_blob)
    except (ValueError, TypeError):
        return None
    if not isinstance(frontmatter, dict):
        return None

    if frontmatter.get("schema_version") != _SCHEMA_VERSION:
        return None
    if frontmatter.get("kind") != "cron-followup":
        return None

    delivery_intent = frontmatter.get("delivery_intent")
    if delivery_intent not in DELIVERY_INTENT_VALUES:
        return None

    for required_string_key in ("run_id", "job_id", "job_name", "family", "target_agent"):
        value = frontmatter.get(required_string_key)
        if not isinstance(value, str) or not value:
            return None

    reporting_policy = frontmatter.get("reporting_policy")
    if reporting_policy not in REPORTING_POLICY_VALUES:
        return None

    forward_target = frontmatter.get("forward_target")
    if delivery_intent == "forward_to_user":
        if not _is_valid_forward_target(forward_target):
            return None
    elif forward_target is not None and not _is_valid_forward_target(forward_target):
        # If the writer included a forward_target on a non-forward intent,
        # it must still be well-formed; otherwise the body is suspect.
        return None

    summary_short = frontmatter.get("summary_short")
    if delivery_intent != "silent":
        if not isinstance(summary_short, str) or not summary_short:
            return None
        if len(summary_short) > 200:
            return None
    elif summary_short is not None and not isinstance(summary_short, str):
        return None

    legacy_flag = frontmatter.get("legacy_structured_relay")
    if legacy_flag is not None and not isinstance(legacy_flag, bool):
        return None

    # Forward-compat: preserve unknown top-level keys verbatim. The caller
    # may add new fields (e.g. trace_id, parent_correlation) before the
    # parser knows about them; refusing on unknown keys would break the
    # writer-first deployment order.
    return frontmatter


def _is_valid_forward_target(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    for key in _FORWARD_TARGET_KEYS:
        item = value.get(key)
        if not isinstance(item, str) or not item:
            return False
    return True
