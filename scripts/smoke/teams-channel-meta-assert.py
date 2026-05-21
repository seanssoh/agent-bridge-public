#!/usr/bin/env python3
"""Assert the Teams channel-meta JSON shape (smoke helper for #1022).

Extracted to a sidecar file (file-as-argv) to avoid an interpreter heredoc-stdin
site in scripts/smoke-test.sh — see KNOWN_ISSUES.md footgun #11 / lint-heredoc-ban.
"""
import json
import sys

meta = json.loads(sys.argv[1])
assert meta["source"] == "teams", meta
assert meta["chat_id"] == "chat-smoke", meta
assert meta["attachment_count"] == "1", meta
assert meta["attachment_names"] == "smoke.html", meta
assert "attachments" not in meta, meta
assert all(isinstance(k, str) and isinstance(v, str) for k, v in meta.items()), meta
