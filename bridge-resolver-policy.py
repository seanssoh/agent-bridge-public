#!/usr/bin/env python3
"""Issue #1991 resolver policy decision + schema validation.

Reads the SHIPPED closed allow-list (runtime-templates/shared/
prompt-resolver-actions.json) and an optional install-local override, and
decides whether a (prompt_kind, confidence) may be auto-actioned and with which
SEMANTIC key tokens.

Security contract enforced here:
  - Default-deny: any prompt_kind not present-and-enabled is denied.
  - Closed token vocabulary: a row whose keys contain a token outside
    {confirm, select_first, down, up, y, n} is treated as INVALID -> deny. Pane
    text never reaches this file; only the typed kind + confidence do.
  - Confidence gate: required_confidence high rejects low/unknown confidence.
  - Local override is DEMOTE-ONLY: it may disable (deny) a shipped-allowed row;
    it may NEVER enable a kind the shipped policy denies, and it may never add a
    new auto-actionable kind. Merge is a deny-wins intersection.
  - Schema validation: a malformed shipped policy -> deny (fail closed).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# The closed semantic token vocabulary a policy row may name. This MUST match
# the declared vocab in prompt-resolver-actions.json ("confirm|select_first|
# down|up|y|n", lowercase). bridge_tmux_send_picker_key also accepts uppercase
# Y/N, but the SHIPPED policy never uses them; we restrict policy validation to
# the six declared lowercase tokens so a policy row cannot smuggle an
# unexpected-case token past the schema gate (codex r1 finding 7). A row naming
# anything outside this set is invalid -> the kind is denied.
CLOSED_TOKENS = frozenset({"confirm", "select_first", "down", "up", "y", "n"})

CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2}


def _load_json(path: str | None) -> dict | None:
    if not path:
        return None
    p = Path(path)
    if not p.is_file():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def _index_actions(policy: dict | None) -> dict[str, dict]:
    """Map prompt_kind -> row, validating each row. Invalid rows are dropped
    (so they fall to default-deny)."""
    out: dict[str, dict] = {}
    if not policy:
        return out
    actions = policy.get("actions")
    if not isinstance(actions, list):
        return out
    for row in actions:
        if not isinstance(row, dict):
            continue
        kind = row.get("prompt_kind")
        if not isinstance(kind, str) or not kind:
            continue
        # keys must be a list of closed tokens (empty is fine for deny rows).
        keys = row.get("keys", [])
        if not isinstance(keys, list):
            continue
        if any((not isinstance(k, str)) or (k not in CLOSED_TOKENS) for k in keys):
            # An out-of-vocabulary token poisons the row -> drop it (deny).
            continue
        out[kind] = row
    return out


def _row_allows(row: dict, confidence: str) -> tuple[bool, list[str]]:
    if not bool(row.get("enabled", False)):
        return (False, [])
    if str(row.get("action", "")) == "deny":
        return (False, [])
    keys = row.get("keys", [])
    if not keys:
        return (False, [])
    required = str(row.get("required_confidence", "high"))
    req_rank = CONFIDENCE_RANK.get(required, 2)
    have_rank = CONFIDENCE_RANK.get(str(confidence), -1)
    if have_rank < req_rank:
        return (False, [])
    return (True, list(keys))


def cmd_decide(args: argparse.Namespace) -> int:
    shipped = _index_actions(_load_json(args.shipped))
    local = _index_actions(_load_json(args.local))

    kind = args.prompt_kind
    confidence = args.confidence

    row = shipped.get(kind)
    if row is None:
        # Not in shipped policy -> default deny.
        print("deny\t")
        return 0

    allow, keys = _row_allows(row, confidence)
    if not allow:
        print("deny\t")
        return 0

    # Deny-wins local demote: if the local override has a row for this kind that
    # disables it (or sets action=deny / empty keys), demote to deny. The local
    # file can NEVER promote — we only consult it to turn an allow into a deny.
    if kind in local:
        l_allow, _ = _row_allows(local[kind], confidence)
        if not l_allow:
            print("deny\t")
            return 0

    print("allow\t" + " ".join(keys))
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    """Validate the shipped policy schema. Exit 0 if it parses and every row is
    well-formed (closed tokens, known fields). Exit 1 otherwise. Used by the
    smoke as a schema gate."""
    raw = _load_json(args.shipped)
    if raw is None:
        print("invalid: shipped policy missing or not a JSON object", file=sys.stderr)
        return 1
    actions = raw.get("actions")
    if not isinstance(actions, list) or not actions:
        print("invalid: 'actions' missing or empty", file=sys.stderr)
        return 1
    seen = set()
    for row in actions:
        if not isinstance(row, dict):
            print("invalid: action row is not an object", file=sys.stderr)
            return 1
        kind = row.get("prompt_kind")
        if not isinstance(kind, str) or not kind:
            print("invalid: row missing prompt_kind", file=sys.stderr)
            return 1
        if kind in seen:
            print(f"invalid: duplicate prompt_kind {kind}", file=sys.stderr)
            return 1
        seen.add(kind)
        keys = row.get("keys", [])
        if not isinstance(keys, list):
            print(f"invalid: {kind} keys not a list", file=sys.stderr)
            return 1
        for k in keys:
            if not isinstance(k, str) or k not in CLOSED_TOKENS:
                print(f"invalid: {kind} has out-of-vocabulary key token {k!r}", file=sys.stderr)
                return 1
        if "enabled" in row and not isinstance(row["enabled"], bool):
            print(f"invalid: {kind} enabled not a bool", file=sys.stderr)
            return 1
    # The dangerous kinds MUST be deny (defense-in-depth: catch a shipped-policy
    # regression that accidentally enables one).
    must_deny = {"billing", "usage", "plan-upgrade", "permission", "overwrite_confirm",
                 "feedback", "context_pressure", "unknown_interactive"}
    idx = _index_actions(raw)
    for kind in must_deny:
        row = idx.get(kind)
        if row is None:
            continue
        allow, _ = _row_allows(row, "high")
        if allow:
            print(f"invalid: dangerous kind {kind} is auto-actionable (must be deny)", file=sys.stderr)
            return 1
    print("ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    d = sub.add_parser("decide")
    d.add_argument("--shipped", required=True)
    d.add_argument("--local", default="")
    d.add_argument("--prompt-kind", required=True)
    d.add_argument("--confidence", default="high")
    d.set_defaults(handler=cmd_decide)

    v = sub.add_parser("validate")
    v.add_argument("--shipped", required=True)
    v.set_defaults(handler=cmd_validate)

    args = parser.parse_args()
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
