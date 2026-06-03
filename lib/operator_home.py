#!/usr/bin/env python3
"""Canonical SSOT for the operator's Agent Bridge home (issue #1497 Phase 2).

Phase 1 (`82eea6df`) closed the per-*agent* home channel
(`BRIDGE_AGENT_HOME_RESOLVED` + the bash→Python resolver parity). Phase 2
closes the *operator*-home channel: the bridge runtime root
(`$BRIDGE_HOME`, default `~/.agent-bridge`) used to be resolved by four
independent, non-delegating Python functions plus six inline resolvers
inside `bridge-queue.py`. Each one re-implemented the same precedence; a
drift in one (e.g. dropping the `.strip()` or the empty-default guard)
would silently route a subset of callers at a different home.

`operator_home()` is the single resolver they now share. It is stdlib-only
and NEVER runs at import time — callers invoke it explicitly so importing
this module has no side effects (the every-session hook layer imports it).

Precedence (mirrors the bash contract `${BRIDGE_HOME:-$HOME/.agent-bridge}`,
plus the whitespace/`~` normalization the Python resolvers already applied):

  1. `$BRIDGE_HOME` when set to a non-empty value (after `strip()`), with
     `~` expanded.
  2. `~/.agent-bridge` otherwise.

FOOTGUN GUARD (do not "simplify" away): the empty-string default on the
environment lookup and the `if explicit` guard are load-bearing. A naive
form that drops the default and calls `.expanduser()` straight on the
lookup result raises `AttributeError: 'NoneType' object has no attribute
...` whenever `BRIDGE_HOME` is unset — and `bridge_home_dir()` runs at
hook-load in *every* session, so that would crash every session. The
empty-string default plus the truthiness guard keep the unset case safe.
"""

from __future__ import annotations

import os
from pathlib import Path


def operator_home() -> Path:
    """Return the operator's Agent Bridge home as a ``Path``.

    ``$BRIDGE_HOME`` (explicit override, whitespace-stripped and
    ``~``-expanded) wins; otherwise ``~/.agent-bridge``. Never raises when
    ``BRIDGE_HOME`` is unset (see the module footgun note).
    """
    explicit = os.environ.get("BRIDGE_HOME", "").strip()  # noqa: iso-helper-boundary — os.environ (.environ) false-matches the .env boundary pattern; BRIDGE_HOME is the operator runtime root, not an isolated artifact
    if explicit:
        return Path(explicit).expanduser()
    return Path.home() / ".agent-bridge"
