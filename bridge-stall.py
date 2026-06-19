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

# Raw provider/system error prefixes that should break out of an in-agent
# block and reach classification even when they immediately follow a glyph
# line without a blank separator. Without this escape hatch, a real stall
# like `Error: HTTP 429 too many requests` arriving directly under a codex
# `• Running smoke` head line would be swallowed by the in-block skip — an
# actually-rate-limited agent would appear idle to bridge-stall.
#
# Anchored at the *raw* line start (no leading whitespace allowed) + word
# boundary + colon-or-whitespace separator. Indentation matters here:
# codex renders tool/diff output as indented continuation lines under a
# glyph head, and a continuation that quotes a prior error (e.g.
# `  Error: HTTP 429 ...` two spaces in, transcript inside a tool block)
# must NOT escape. Only flush-left raw provider output qualifies. Casual
# narration ("the user got an error", "errors are common") and diff bodies
# ("1 +error_message =") cannot match the line-start anchor either.
# Tool-output continuations like `└ tool: error: file not found` are not
# affected here — those start with the `└` glyph and are skipped by
# AGENT_GLYPH_PREFIXES before this rule is evaluated. The keyword set is
# the minimal shape of raw provider/runtime error lines we have actually
# seen in stall captures; extend only when a new false-negative is
# reproduced.
RAW_ERROR_PREFIXES_RE = re.compile(
    r"^(error|err|warning|fatal|panic|exception)\b\s*[:\s]",
    re.IGNORECASE,
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
    # head line followed by continuation lines that carry no glyph (wrapped
    # diff bodies, multi-line tool stdout). Glyph-only filtering let those
    # continuation lines reach classify and match e.g. "401 Unauthorized"
    # quoted from a smoke test or from a tracked review report.
    #
    # An earlier version of this rule treated the block as "indented lines
    # only" — but codex wraps long head lines too, e.g.
    #     • Added /very/long/path/to/file.md (+34
    #     -0)
    #     1 +...
    # where `-0)` lands flush-left and looks like a block exit. Once exited,
    # the indented diff body that followed was eligible to match. The rule
    # below treats *any* non-empty line inside an agent block as part of the
    # block, regardless of indentation; the block ends on the next blank line.
    # A subsequent glyph line restarts the block. This is broader than the
    # original indented-only rule but matches how codex actually structures
    # output: top-level pane items are separated by blank lines, and any
    # rendering inside one item is the agent narrating. Issue #329 Track D's
    # walk-line-by-line semantics and matched_line_hash dedup are preserved.
    #
    # Escape hatch: raw provider/system error lines (`Error: HTTP 429 ...`,
    # `Fatal: ...`, etc.) that land directly under a glyph head without a
    # blank separator MUST still classify — otherwise an actually-rate-
    # limited agent appears idle to bridge-stall. The block-skip is gated
    # on RAW_ERROR_PREFIXES_RE matched against the *raw* line (with
    # original leading whitespace) so an indented continuation that quotes
    # an error inside a tool block (`  Error: HTTP 429 ...` two spaces in)
    # stays suppressed; only flush-left raw provider output escapes. Diff
    # bodies (`1 +HTTP/1.1 401 Unauthorized`), tool output continuations
    # (`└ HTTP/1.1 200 OK` — already glyph-skipped), and flush-left wrap
    # continuations (`-0)`) do not start with one of the raw-error keywords
    # and therefore stay suppressed.
    in_agent_block = False
    for raw in normalized.splitlines():
        stripped = raw.strip()
        if not stripped:
            in_agent_block = False
            continue
        if stripped.startswith(AGENT_GLYPH_PREFIXES):
            in_agent_block = True
            continue
        if in_agent_block and not RAW_ERROR_PREFIXES_RE.match(raw):
            continue
        haystack = stripped.lower()
        for classification, patterns in PATTERN_GROUPS:
            for pattern in patterns:
                if re.search(pattern, haystack, flags=re.IGNORECASE):
                    return classification, pattern, _normalize_matched_line(stripped)
    return "", "", ""


# ---------------------------------------------------------------------------
# Issue #1991 safety floor: detect-only typed blocked-prompt classifier.
#
# This is a SIBLING of bridge-tmux.sh::bridge_tmux_claude_blocker_state_from_text
# (which returns a coarse single-token state many callers compare exactly). It
# is intentionally NOT that function and never changes its output. It runs in
# the daemon's all-pane safety-floor sweep purely to DETECT a stuck interactive
# prompt and feed it to the deterministic escalation path. It NEVER sends keys,
# never selects a UI option, and never asks an LLM to read the pane (that is the
# v0.17 resolver, out of scope here).
#
# Captured pane text is attacker-controlled. We only HASH it and match known
# structured affordances; we never source/eval/interpolate it. The escalation
# message prefers hashes + metadata; only the shared report keeps a short
# fenced excerpt.
#
# Confidence gating lives partly here (ready-prompt rejection, structured
# affordance requirement, mid-render rejection) and partly in the daemon caller
# (Claude-only, tail-owned, 2-tick stability, deadline). A normal numbered list
# must NOT match.

# A structured picker renders its option list followed by the verbatim
# confirm/cancel tail. Requiring this tail (or a recognized y/n / Press-Enter
# modal signature) is what separates a real modal from a normal numbered list.
PICKER_TAIL_RE = re.compile(r"(?m)^\s*Enter to confirm\s*·\s*Esc to cancel\s*$")

# Per-kind structured signatures. Each entry is (prompt_kind, [required
# fragments — ALL must be present]). The fragments mirror the coarse classifier
# so the typed detector cannot drift away from it, plus the billing/usage
# picker that the coarse classifier does not name (it surfaces as
# interactive_picker via the stall analyzer). Order matters: billing is checked
# before the generic summary picker so a usage picker is not mislabeled.
PROMPT_SIGNATURES: list[tuple[str, list[str]]] = [
    ("trust", ["Quick safety check:", "Yes, I trust this folder"]),
    ("billing", ["Stop and wait for limit to reset"]),
    ("billing", ["Switch to extra usage"]),
    ("billing", ["Switch to Team plan"]),
    ("summary", ["Resume from summary (recommended)", "Resume full session as-is"]),
    ("devchannels", ["WARNING: Loading development channels", "I am using this for local development"]),
    ("feedback", ["How is Claude doing this session?", "0: Dismiss"]),
    ("permission", ["Allow ", "for this session?", "(y/n)"]),
    ("permission", ["Overwrite?", "(y/n)"]),
    ("context_pressure", ["context pressure", "Press Enter to"]),
]

# A ready/input-ready prompt or active mid-render output in the tail means the
# pane is NOT stuck on a modal. These are rejection signals applied to the tail
# region only.
#   - "waiting for your input" / "Type your ..." — explicit idle prompt text.
#   - A BARE prompt caret line ("❯" / ">" / "›" with only whitespace after) is
#     the idle Claude input box AFTER a modal has been dismissed. This is NOT a
#     picker selection row: a live picker always renders its caret ON an option
#     ("❯ 1. option"), never bare. Rejecting a bare-caret tail prevents a
#     transcript that quotes a past picker (option rows + the confirm tail) from
#     escalating once the agent has returned to the ready prompt (codex r3).
READY_PROMPT_RE = re.compile(
    r"(?m)^\s*(?:[❯>›]\s*$|[❯>›]\s*(?:waiting for your input|Type your)|waiting for your input|Type your)",
    re.IGNORECASE,
)
# Claude renders a working spinner / token meter while actively producing
# output. If the tail still shows live work, the prompt has not settled.
ACTIVE_OUTPUT_RE = re.compile(
    r"(?:esc to interrupt|·\s*\d+\s*tokens|Thinking…|Working…|✶|✻\s+\w+ing)",
    re.IGNORECASE,
)

# Coarse-token map: only the prompt_kinds that the coarse blocker classifier
# also names map back to a coarse token (for the daemon's compatibility-stable
# hash field). billing/unknown_interactive have no coarse equivalent.
COARSE_STATE_BY_KIND = {
    "trust": "trust",
    "summary": "summary",
    "devchannels": "devchannels",
    "feedback": "feedback_survey",
    "permission": "permission_grant",
    "context_pressure": "context_pressure",
}

# Picker-style prompt kinds render as an option-list modal whose ONLY reliable
# structured affordance is the picker confirm tail ("Enter to confirm · Esc to
# cancel"). The verbatim option strings can also appear quoted in prose /
# scrollback / a review transcript, so these kinds MUST have a structured
# affordance in the tail or they are NOT treated as a live blocked modal
# (otherwise quoted text would escalate — codex r1 finding 1). The other kinds
# carry their own inherent affordance in the matched signature itself
# (permission/overwrite end in "(y/n)", context_pressure has "Press Enter to",
# feedback has the "N: Dismiss" option row), so they do not need the tail.
PICKER_STYLE_KINDS = frozenset({"trust", "summary", "devchannels", "billing"})


def _tail_region(normalized: str, tail_lines: int = 40) -> str:
    lines = normalized.splitlines()
    if len(lines) > tail_lines:
        lines = lines[-tail_lines:]
    return "\n".join(lines)


# A real Claude Code picker renders each option on its own line as
# "<glyph-or-space> <n>. <option text>". Two such option rows is the minimum
# shape that distinguishes a structured chooser from a one-off "Press Enter"
# acknowledgement line embedded in prose.
PICKER_OPTION_ROW_RE = re.compile(r"(?m)^[ \t❯>›]*\d+\.\s+\S")


def _structured_affordance(tail: str) -> bool:
    # Confirms a KNOWN modal (already matched by its verbatim signature) is a
    # live blocked prompt: the picker confirm tail, a (y/n) confirm, a "Press
    # Enter to" acknowledgement, or the feedback survey's "N: Dismiss" option
    # row. This is the SUPPORTING evidence for a known signature only — it is
    # deliberately NOT used to admit UNKNOWN prompts (a bare "Press Enter to"
    # or "(y/n)" in prose is far too loose to mint an unknown escalation; see
    # _unknown_modal_shape — codex r2). A bare numbered list does NOT qualify.
    if PICKER_TAIL_RE.search(tail):
        return True
    if "(y/n)" in tail:
        return True
    if re.search(r"Press Enter to", tail):
        return True
    if re.search(r"(?m)^\s*\d+:\s*Dismiss\s*$", tail):
        return True
    return False


def _picker_tail_is_last_line(tail: str) -> bool:
    # True iff the exact picker confirm tail ("Enter to confirm · Esc to cancel")
    # is the LAST non-blank line of the captured pane. A live picker renders its
    # footer at the literal bottom of the pane; a transcript/log that merely
    # QUOTES a picker footer has trailing content after it (codex r3). Used by
    # both the known picker-style gate and the unknown-modal gate so neither can
    # be tripped by quoted/logged footer text.
    lines = [ln for ln in tail.splitlines() if ln.strip()]
    return bool(lines) and bool(PICKER_TAIL_RE.match(lines[-1]))


def _unknown_modal_shape(tail: str) -> bool:
    # The STRICT gate for admitting an UNKNOWN interactive prompt (no known
    # signature matched). Requires ALL of:
    #   1. the exact picker confirm tail is the LAST non-blank line (live footer,
    #      not a quoted/logged one with trailing content — codex r3); and
    #   2. at least two numbered option rows above it — the structured-chooser
    #      shape that a normal numbered list / prose / "Press Enter" line lacks.
    # This rejects benign prose, stray "(y/n)", and quoted/logged picker footers
    # that have trailing content, while still admitting a real unknown picker.
    #
    # ACCEPTED RESIDUAL (codex r4, by design): if the captured pane is byte-for-
    # byte the bottom of a live picker — >=2 option rows then the verbatim Claude
    # footer "Enter to confirm · Esc to cancel" as the literal last line — it is
    # INDISTINGUISHABLE from a real picker by pane-text shape alone (e.g. a
    # transcript whose quote ENDS exactly at the footer). No pane-text classifier
    # can separate a perfect reproduction of a live picker from the real thing,
    # and we deliberately do NOT add a keyword/preamble heuristic ("transcript",
    # "quoted", …): pane text is attacker-controlled and must never be
    # interpreted semantically — such a filter is trivially bypassed by omitting
    # the word. This residual is SAFE BY CONSTRUCTION: the floor is observe-only
    # (a false match escalates to a HUMAN, never auto-actions), and the daemon
    # gates it further with Claude-only + an ACTIVE live session + 2-tick
    # content-hash stability (the same bytes must persist >=2 sweeps) + the
    # unknown 5-min deadline + dedup/30-min-cooldown/per-pass-cap. A static
    # quoted-picker tail that stays byte-stable in a live, otherwise-idle Claude
    # pane for 5+ minutes is itself anomalous and worth one (deduped) human glance.
    if not _picker_tail_is_last_line(tail):
        return False
    return len(PICKER_OPTION_ROW_RE.findall(tail)) >= 2


def detect_claude_blocked_prompt(text: str) -> dict[str, object]:
    # Detect-only. Returns matched/prompt_kind/confidence + hash fields. The
    # daemon enforces engine-scoping, 2-tick stability, and the deadline; this
    # function enforces structured-affordance + ready/active-output rejection.
    #
    # Issue #2007: this is the CLAUDE detector, unchanged from the #1991 floor.
    # The Codex sibling lives in detect_codex_blocked_prompt and the engine
    # dispatch is detect_blocked_prompt(text, engine). Keeping the Claude body
    # byte-identical is what guarantees no #1991 regression.
    normalized = normalize_excerpt(text, 8192)
    tail = _tail_region(normalized)

    result: dict[str, object] = {
        "matched": 0,
        "prompt_kind": "",
        "confidence": "",
        "coarse_state": "none",
        "content_hash": "",
        "matched_line_hash": "",
        "excerpt_hash": hashlib.sha256(normalized.encode("utf-8")).hexdigest() if normalized else "",
    }

    if not tail.strip():
        return result

    # Rejection gates first: a ready prompt or active mid-render output means
    # the pane is not blocked on a settled modal.
    if READY_PROMPT_RE.search(tail) or ACTIVE_OUTPUT_RE.search(tail):
        return result

    matched_kind = ""
    matched_fragment = ""
    for kind, fragments in PROMPT_SIGNATURES:
        if all(fragment in tail for fragment in fragments):
            matched_kind = kind
            matched_fragment = fragments[-1]
            break

    confidence = "high"
    if matched_kind:
        # codex r1 finding 1 + r3: picker-style kinds (trust/summary/devchannels/
        # billing) match only verbatim option strings, which also appear quoted
        # in prose/scrollback/transcripts. Require the picker confirm tail to be
        # the LAST non-blank line (a LIVE footer, not a quoted/logged one) or
        # they are NOT a live blocked modal — hard-reject, do NOT escalate quoted
        # text. The other kinds carry their own inherent affordance in the
        # signature (y/n / Press-Enter / N: Dismiss), confirmed by
        # _structured_affordance.
        if matched_kind in PICKER_STYLE_KINDS:
            if not _picker_tail_is_last_line(tail):
                return result
        elif not _structured_affordance(tail):
            return result
    elif _unknown_modal_shape(tail):
        # codex r1 finding 2 + codex r2: no KNOWN signature matched, but the tail
        # has the STRICT structured-chooser shape (picker confirm tail + >=2
        # numbered option rows) — an unknown interactive prompt. Keep it (low
        # confidence) so the daemon's longer unknown-prompt deadline applies,
        # rather than dropping a real stuck modal. The strict shape rejects
        # benign "Press Enter to ..." / "(y/n)" prose that a looser affordance
        # check would wrongly admit (codex r2 false-positive).
        matched_kind = "unknown_interactive"
        matched_fragment = ""
        confidence = "low"
    else:
        # No known signature and no strict unknown-modal shape: not a blocked
        # modal (a normal numbered list / prose / scrollback). Do not match.
        return result

    # content_hash: stable hash over the tail region of the recognized modal so
    # dedupe distinguishes devchannels vs trust vs permission vs billing vs
    # unknown and so a new prompt (different tail) re-keys.
    content_hash = hashlib.sha256(tail.encode("utf-8")).hexdigest()[:16]

    result.update(
        {
            "matched": 1,
            "prompt_kind": matched_kind,
            "confidence": confidence,
            "coarse_state": COARSE_STATE_BY_KIND.get(matched_kind, "none"),
            "content_hash": content_hash,
            # Fold typed detail into matched_line_hash so the daemon's existing
            # dedup keyspace distinguishes prompt kinds while the coarse
            # activity_state surfaces stay stable (design §Compatibility rule).
            "matched_line_hash": f"prompt:{matched_kind}:{content_hash}",
            "matched_fragment": matched_fragment,
        }
    )
    return result


# ---------------------------------------------------------------------------
# Issue #2007 safety-floor extension: detect-only typed Codex blocked-prompt
# classifier. Sibling of detect_claude_blocked_prompt with the same contract
# (detect-only, never sends keys, only hashes/matches affordances on untrusted
# pane text) but the Codex hook-trust / unknown-modal signatures. The daemon
# safety-floor sweep dispatches to this by engine; the rc2 floor remains
# observe-only.
#
# Codex renders its top-level menu options EITHER numbered (`1. Review hooks`)
# OR with an unnumbered `›` selector prefix (`›  Review hooks`); the 6 signature
# strings are byte-identical across the 1-hook and 10-hook cases. The signature
# match uses substring checks (the strings appear mid-line, after any prefix),
# so it is inherently numbering/prefix-independent without an explicit strip
# (design Addendum point 1, cm-prod 0.140 probe).

# The verbatim Codex hook-trust footer. Distinct from the Claude picker tail
# ("Enter to confirm · Esc to cancel"): Codex renders this exact line. It must
# be the LAST non-blank line of a live prompt (a quoted/logged footer has
# trailing content after it), mirroring the Claude last-line anchor.
CODEX_FOOTER_RE = re.compile(
    r"(?i)^press enter to confirm or esc to go back$"
)

# Codex hook-trust signature: ALL of these must be present. These are substring
# checks over the tail — NOT anchored to the row start — so they are inherently
# numbering/prefix-independent (`1. Review hooks` and `›  Review hooks` both
# contain the substring `Review hooks`). The "new or changed" fragment is
# singular for 1 hook, plural for 2+; either satisfies it. ALL are required.
CODEX_HOOK_TRUST_REQUIRED = (
    "Hooks need review",
    "Review hooks",
    "Trust all and continue",
    "Continue without trusting",
)
CODEX_HOOK_TRUST_EITHER = (
    "hook is new or changed",
    "hooks are new or changed",
)


def _codex_footer_is_last_line(tail: str) -> bool:
    # True iff the exact Codex confirm footer is the LAST non-blank line of the
    # captured pane. A live Codex modal renders this footer at the literal bottom
    # of the pane; a transcript/log that merely QUOTES it has trailing content
    # after it (same last-line anchor the Claude path uses against quoted text).
    lines = [ln for ln in tail.splitlines() if ln.strip()]
    if not lines:
        return False
    return bool(CODEX_FOOTER_RE.match(lines[-1].strip()))


def _codex_numbered_option_rows(tail: str) -> int:
    # Count Codex option rows (selector/number prefix stripped) in the tail. Two
    # such rows is the minimum structured-chooser shape that distinguishes a real
    # modal from a one-off line in prose. Only count rows that carried an actual
    # selector/number prefix so plain prose lines do not inflate the count.
    count = 0
    for raw in tail.splitlines():
        if re.match(r"^[ \t]*(?:[›❯>]\s*|\d+\.\s+)\S", raw):
            count += 1
    return count


def detect_codex_blocked_prompt(text: str) -> dict[str, object]:
    # Detect-only Codex sibling. Returns the same field shape as the Claude
    # detector so the daemon caller is engine-agnostic. NEVER sends keys.
    normalized = normalize_excerpt(text, 8192)
    tail = _tail_region(normalized)

    result: dict[str, object] = {
        "matched": 0,
        "prompt_kind": "",
        "confidence": "",
        "coarse_state": "none",
        "content_hash": "",
        "matched_line_hash": "",
        "excerpt_hash": hashlib.sha256(normalized.encode("utf-8")).hexdigest() if normalized else "",
    }

    if not tail.strip():
        return result

    # Reject ready/active-output tails: a settled, blocked modal must not show a
    # live ready prompt or mid-render output. Reuse the Claude rejection signals
    # (the Codex ready caret `›`/`❯` and active-output spinners overlap enough
    # that the shared gates are correct here too).
    if READY_PROMPT_RE.search(tail) or ACTIVE_OUTPUT_RE.search(tail):
        return result

    matched_kind = ""
    matched_fragment = ""
    confidence = ""

    has_all_required = all(frag in tail for frag in CODEX_HOOK_TRUST_REQUIRED)
    has_either = any(frag in tail for frag in CODEX_HOOK_TRUST_EITHER)
    footer_last = _codex_footer_is_last_line(tail)

    if has_all_required and has_either and footer_last:
        # High-confidence Codex hook-trust prompt: all 6 signature strings plus
        # the confirm footer as the live last line. The footer-last-line anchor
        # rejects a transcript/log that merely quotes the prompt.
        matched_kind = "codex_hook_trust"
        matched_fragment = "Trust all and continue"
        confidence = "high"
    elif footer_last and _codex_numbered_option_rows(tail) >= 2:
        # Low-confidence unknown Codex modal: the exact confirm footer as the
        # live last line plus >=2 numbered/selector option rows. The daemon's
        # longer unknown-prompt deadline applies. Benign prose / a quoted footer
        # with trailing content does not reach here.
        matched_kind = "codex_unknown_interactive"
        matched_fragment = ""
        confidence = "low"
    else:
        return result

    content_hash = hashlib.sha256(tail.encode("utf-8")).hexdigest()[:16]
    result.update(
        {
            "matched": 1,
            "prompt_kind": matched_kind,
            "confidence": confidence,
            "coarse_state": "none",
            "content_hash": content_hash,
            "matched_line_hash": f"prompt:{matched_kind}:{content_hash}",
            "matched_fragment": matched_fragment,
        }
    )
    return result


def detect_blocked_prompt(text: str, engine: str = "claude") -> dict[str, object]:
    # Engine dispatcher for the safety-floor detect-only classifier. Defaults to
    # the Claude detector for back-compat (the #1991 daemon caller passed no
    # engine). Issue #2007 adds the Codex path. Any other engine returns the
    # unmatched result (the daemon also gates engine separately).
    if engine == "codex":
        return detect_codex_blocked_prompt(text)
    return detect_claude_blocked_prompt(text)


def cmd_detect_prompt(args: argparse.Namespace) -> int:
    text = read_capture(args.capture_file)
    payload = detect_blocked_prompt(text, getattr(args, "engine", "claude"))
    if args.format == "shell":
        print(f"PROMPT_MATCHED={int(payload['matched'])}")
        print(f"PROMPT_KIND={json.dumps(payload['prompt_kind'])}")
        print(f"PROMPT_CONFIDENCE={json.dumps(payload['confidence'])}")
        print(f"PROMPT_COARSE_STATE={json.dumps(payload['coarse_state'])}")
        print(f"PROMPT_CONTENT_HASH={json.dumps(payload['content_hash'])}")
        print(f"PROMPT_MATCHED_LINE_HASH={json.dumps(payload['matched_line_hash'])}")
        print(f"PROMPT_EXCERPT_HASH={json.dumps(payload['excerpt_hash'])}")
    else:
        print(json.dumps(payload, ensure_ascii=False))
    return 0


def cmd_analyze(args: argparse.Namespace) -> int:
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


def main() -> int:
    # `analyze` is the long-standing default (positional, no subparser) so
    # existing callers — including the daemon stall analyzer — keep working
    # verbatim. `detect-prompt` is the new #1991 safety-floor sibling.
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("analyze", "detect-prompt"))
    parser.add_argument("--capture-file")
    parser.add_argument("--max-bytes", type=int, default=8192)
    parser.add_argument("--format", choices=("json", "shell"), default="json")
    parser.add_argument("--json", action="store_true")
    # Issue #2007: detect-prompt dispatches to the Claude or Codex detector by
    # engine. Defaults to claude so the #1991 daemon caller and any other
    # existing invocation keep their behavior verbatim.
    parser.add_argument("--engine", choices=("claude", "codex"), default="claude")
    args = parser.parse_args()

    if args.command == "detect-prompt":
        return cmd_detect_prompt(args)
    return cmd_analyze(args)


if __name__ == "__main__":
    raise SystemExit(main())
