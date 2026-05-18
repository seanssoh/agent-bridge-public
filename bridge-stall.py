#!/usr/bin/env python3
"""bridge-stall.py — normalize recent pane text and classify stall patterns."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import sys
from pathlib import Path

ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")

PATTERN_GROUPS: list[tuple[str, list[str]]] = [
    # interactive_picker comes first: when a session shows the rate-limit
    # picker the pane also contains "hit your limit" (rate_limit), but the
    # correct action is to escalate to the admin agent for a keypress
    # decision — not to retry-nudge the picker, which would type generic
    # text into the picker prompt and be ignored. first-match-wins routes
    # mixed-pane cases to the picker handler.
    (
        "interactive_picker",
        # Each pattern is line-anchored with re.MULTILINE so that prose like
        # "if billing permits, switch to extra usage for this job" cannot
        # classify as a picker. Real Claude Code pickers render each option
        # on its own line as "<glyph or whitespace> <number>. <option text>",
        # and the prompt tail is the verbatim "Enter to confirm · Esc to
        # cancel" line.
        [
            r"(?m)^[ \t❯>]*\d+\.\s+Stop and wait for limit to reset\s*$",
            r"(?m)^[ \t❯>]*\d+\.\s+Switch to extra usage\s*$",
            r"(?m)^[ \t❯>]*\d+\.\s+Switch to Team plan\s*$",
            r"(?m)^[ \t❯>]*\d+\.\s+Resume from summary \(recommended\)\s*$",
            r"(?m)^[ \t❯>]*\d+\.\s+Resume full session as-is\s*$",
            r"(?m)^Enter to confirm · Esc to cancel\s*$",
        ],
    ),
    (
        "rate_limit",
        [
            r"selected model is at capacity",
            r"at capacity",
            r"hit your limit",
            r"rate limit exceeded",
            r"rate_limit_exceeded",
            r"too many requests",
            # Issue #329 Track A: bare `\b429\b` matched non-glyph scrollback
            # like A2A task bodies, [cron-dispatch] payloads, vendor incident
            # transcripts, and meta-text quoting the regex itself — producing
            # repeated rate-limit nudges to idle agents because excerpt_hash
            # changed each scan and the max_nudges cap never tripped. Mirror
            # the #161 timeout narrowing: require an HTTP/status/error/code
            # transport qualifier adjacent to the bare 429.
            r"(?:http[\s/]?|status[\s:=]+|error[\s:=]+|code[\s:=]+|api_error_status[\s:=]?)\s*\b429\b",
            r"\b429\b\s*(?:too many|rate|throttl)",
            r"please wait before trying",
            r"try a different model",
            r"quota exceeded",
        ],
    ),
    (
        "auth",
        [
            r"session expired",
            # Issue #329 Track A: bare `unauthorized` matched non-glyph
            # scrollback (A2A bodies, cron-dispatch payloads, CJK prose
            # quoting the term). Require a transport qualifier adjacent to
            # the bare keyword/numeric, mirroring the rate_limit narrowing.
            r"(?:http[\s/]?|status[\s:=]+|error[\s:=]+|code[\s:=]+)\s*\b40[13]\b",
            r"\bunauthorized\b\s*(?:request|access\s+denied|401|api_error)",
            r"\b40[13]\b\s*unauthorized",
            r"login required",
            r"authentication failed",
            r"token expired",
            r"not authenticated",
        ],
    ),
    (
        "network",
        [
            r"econnreset",
            r"econnrefused",
            r"etimedout",
            r"connection refused",
            r"\bconnection\s+reset\s+by\s+peer\b",
            r"\bconnection\s+aborted\b",
            r"\bname\s+or\s+service\s+not\s+known\b",
            r"\bcontext\s+deadline\s+exceeded\b",
            # Issue #161: bare `timeout` / `timed out` matched benign scrollback
            # like Claude Code's `⎿  (timeout 5m)` tool-budget hint, shell
            # `timeout 120000ms`, and documentation strings — producing
            # repeated "retry the transient network error" nudges to idle
            # agents. Require a network-ish subject word next to the timeout
            # so only real transport errors classify as network.
            r"\b(?:connection|request|socket|read|write|fetch|network|upstream|gateway|dns|tcp|tls|ssl|i/o)\s+timed?\s*out\b",
            r"network\s+timeout",
            r"503 service unavailable",
            r"502 bad gateway",
            r"upstream connect error",
        ],
    ),
]

IGNORED_PREFIXES = (
    "[Agent Bridge]",
)

IGNORED_LINES = {
    "A rate-limit or capacity error was detected. Retry the current task now and continue from the current state.",
    "A transient network or provider error was detected. Retry the current task and continue if the connection is healthy now.",
    "The current task appears stalled. Check the current state, summarize what is blocking progress, and continue if work can proceed.",
}

# Agent-authored output glyphs. Any line beginning with one of these is the
# agent narrating — never raw provider error output.
#   Claude Code: ❯ > › ⏺ ⎿ ✢ ✻ ✱ ℹ ✓ ✗  (prompt caret, tool-call markers,
#       status pips).
#   Codex CLI: • │ └  (tool/action bullet, continuation body, continuation
#       tail). Without codex glyphs here, lines like `└ HTTP/1.1 401
#       Unauthorized` produced by an intentional smoke test re-fire as
#       false-positive auth stalls every daemon tick.
AGENT_GLYPH_PREFIXES = (
    "❯", ">", "›", "⏺", "⎿", "✢", "✻", "✱", "ℹ", "✓", "✗",
    "•", "│", "└",
)


def looks_like_agent_output(stripped: str) -> bool:
    # Re-enter capture after an [Agent Bridge] nudge as soon as we see either
    # a Claude UI glyph (the agent narrating) or a raw provider error line
    # (a fresh failure right after the nudge). The classify() pass below
    # ignores glyph-prefixed lines so the agent narrating a past error does
    # not re-fire a stall against itself (#264). We deliberately keep the
    # PATTERN_GROUPS detector here so glyph-less raw provider errors that
    # land immediately after a nudge — e.g. `Error: 429 Too Many Requests`
    # with no UI prefix — still resume capture and reach classify.
    if not stripped:
        return False
    if stripped.startswith(AGENT_GLYPH_PREFIXES):
        return True
    lowered = stripped.lower()
    for _classification, patterns in PATTERN_GROUPS:
        for pattern in patterns:
            if re.search(pattern, lowered, flags=re.IGNORECASE):
                return True
    return False


def read_capture(path: str | None) -> str:
    if path:
        return Path(path).read_text(encoding="utf-8", errors="ignore")
    return sys.stdin.read()


def normalize_excerpt(text: str, max_bytes: int) -> str:
    text = ANSI_RE.sub("", text.replace("\r", ""))
    lines = []
    skipping_bridge = False
    for raw in text.splitlines():
        stripped = raw.strip()
        if any(stripped.startswith(prefix) for prefix in IGNORED_PREFIXES):
            skipping_bridge = True
            continue
        if skipping_bridge:
            if looks_like_agent_output(stripped):
                skipping_bridge = False
            else:
                continue
        if stripped in IGNORED_LINES:
            continue
        lines.append(raw)
    while lines and not lines[-1].strip():
        lines.pop()
    normalized = "\n".join(lines).strip()
    if not normalized:
        return ""
    encoded = normalized.encode("utf-8")
    if len(encoded) <= max_bytes:
        return normalized
    return encoded[-max_bytes:].decode("utf-8", errors="ignore").lstrip()


def _normalize_matched_line(line: str) -> str:
    # Issue #329 Track D: produce a stable representation of the offending
    # line so the daemon can dedup on the line itself instead of the
    # surrounding excerpt window (which shifts every idle tick). Lower-case
    # plus collapsed whitespace plus trim absorbs cosmetic diffs; truncating
    # to 240 chars bounds the hash input for pathological lines.
    collapsed = re.sub(r"\s+", " ", line.lower()).strip()
    if len(collapsed) > 240:
        collapsed = collapsed[:240]
    return collapsed


def classify(normalized: str) -> tuple[str, str, str]:
    # Issue #264: skip agent-authored lines so the classifier never matches
    # the agent narrating a previous error (e.g. "⏺ inbox empty, no 429
    # reoccurrence"). Without this, agent replies referencing past errors
    # become a self-sustaining stall loop.
    #
    # Block-aware extension: codex renders tool/diff output as a glyph-prefixed
    # head line followed by indented continuation lines that carry no glyph
    # (wrapped diff bodies, multi-line tool stdout). Glyph-only filtering let
    # those wrapped lines reach classify and match e.g. "401 Unauthorized"
    # quoted from a smoke test. Once we enter an agent block on a glyph line,
    # skip subsequent non-empty lines whose RAW text starts with whitespace;
    # exit the block on a blank line or the next non-indented, non-glyph line
    # (which is itself eligible for matching). Issue #329 Track D's
    # walk-line-by-line semantics are preserved so matched_line_hash keeps its
    # dedup behavior.
    in_agent_block = False
    for raw in normalized.splitlines():
        stripped = raw.strip()
        if not stripped:
            in_agent_block = False
            continue
        if stripped.startswith(AGENT_GLYPH_PREFIXES):
            in_agent_block = True
            continue
        if in_agent_block:
            if raw[:1].isspace():
                continue
            in_agent_block = False
        haystack = stripped.lower()
        for classification, patterns in PATTERN_GROUPS:
            for pattern in patterns:
                if re.search(pattern, haystack, flags=re.IGNORECASE):
                    return classification, pattern, _normalize_matched_line(stripped)
    return "", "", ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("analyze",))
    parser.add_argument("--capture-file")
    parser.add_argument("--max-bytes", type=int, default=8192)
    parser.add_argument("--format", choices=("json", "shell"), default="json")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    normalized = normalize_excerpt(read_capture(args.capture_file), max(args.max_bytes, 256))
    classification, matched, matched_line = classify(normalized)
    # Issue #329 Track D: matched_line_hash is the dedup key the daemon uses
    # to decide "same stall as last loop". 16 hex chars (64 bits) is enough
    # collision-resistance for one host's roster. Empty when no line matched
    # (e.g. unknown-classification idle stalls), in which case the daemon
    # falls back to excerpt_hash for the legacy behavior.
    matched_line_hash = (
        hashlib.sha256(matched_line.encode("utf-8")).hexdigest()[:16]
        if matched_line
        else ""
    )
    payload = {
        "classification": classification,
        "matched_pattern": matched,
        "matched_line": matched_line,
        "matched_line_hash": matched_line_hash,
        "excerpt": normalized,
        "excerpt_hash": hashlib.sha256(normalized.encode("utf-8")).hexdigest() if normalized else "",
        "excerpt_lines": len(normalized.splitlines()) if normalized else 0,
    }
    if args.format == "shell":
        print(f"STALL_CLASSIFICATION={json.dumps(payload['classification'])}")
        print(f"STALL_MATCHED_PATTERN={json.dumps(payload['matched_pattern'])}")
        print(f"STALL_MATCHED_LINE_HASH={json.dumps(payload['matched_line_hash'])}")
        print(f"STALL_EXCERPT_HASH={json.dumps(payload['excerpt_hash'])}")
        print(f"STALL_EXCERPT_LINES={int(payload['excerpt_lines'])}")
        print(f"STALL_EXCERPT_B64={json.dumps(base64.b64encode(payload['excerpt'].encode('utf-8')).decode('ascii'))}")
    elif args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
