#!/usr/bin/env python3
"""Bounded AskUserQuestion escalation for autonomous bridge agents (#1569).

Claude Code's ``AskUserQuestion`` (interactive multiple-choice) blocks the
composer *unbounded* waiting for a human selection. For an autonomous bridge
agent that is a hang foot-gun: the composer is stuck on a choice that may never
come and nobody knows why. ``attached`` is NOT a usable "human is present"
signal (operators keep tabs permanently attached without watching), so we do
NOT gate on presence.

Instead the PreToolUse hook (``hooks/tool-policy.py``) short-circuits the
``AskUserQuestion`` tool call and calls into this module, which:

1. Renders the question + its options into channel-friendly text.
2. Posts it to the human channel via ``agb escalate question`` (reusing the
   existing async, channel-routed escalation) AND records the reply-file path
   the human channel / operator writes the answer to.
3. Polls that reply file for a **bounded** window
   (``BRIDGE_ASKUSERQUESTION_WAIT_SECONDS``, default 30s) — never longer.
4. Returns a structured decision:
   - ``answered`` — a human replied within the window with a chosen option;
     the hook tells the agent to proceed with that option.
   - ``proceed_with_note`` — timeout on a reversible/low-stakes question; the
     agent proceeds with a best-judgment default and leaves a durable note.
   - ``blocked`` — timeout on a high-stakes/consequential question; the agent
     must set the task ``blocked`` and the escalation already went to the
     human channel. No silent guess.

The whole point is the BOUND: this module never waits beyond the configured
window. It is import-safe (no side effects at import) and has no dependency on
``tool-policy.py`` so it can be unit-smoked directly.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any

DEFAULT_WAIT_SECONDS = 30
# Hard ceiling so a misconfigured / hostile env value can never reintroduce an
# effectively-unbounded wait (the whole #1569 contract is the bound).
MAX_WAIT_SECONDS = 3600
# Poll cadence for the reply file. Small enough to feel responsive, large
# enough to keep the busy-wait cost negligible across a 30s window.
POLL_INTERVAL_SECONDS = 0.5


def wait_seconds() -> int:
    """Bounded escalation wait, from ``BRIDGE_ASKUSERQUESTION_WAIT_SECONDS``.

    Defaults to :data:`DEFAULT_WAIT_SECONDS` (30). A non-numeric, negative, or
    zero value falls back to the default; values above :data:`MAX_WAIT_SECONDS`
    are clamped so the bound can never be defeated by configuration.
    """
    raw = os.environ.get("BRIDGE_ASKUSERQUESTION_WAIT_SECONDS", "").strip()  # noqa: iso-helper-boundary — os.environ (.environ) false-matches the .env boundary pattern; this is a wait-window knob, not an isolated runtime artifact
    if not raw:
        return DEFAULT_WAIT_SECONDS
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_WAIT_SECONDS
    if value <= 0:
        return DEFAULT_WAIT_SECONDS
    return min(value, MAX_WAIT_SECONDS)


def _high_stakes_env_default() -> bool:
    """Operator-pinned default fallback branch for timeouts.

    ``BRIDGE_ASKUSERQUESTION_HIGH_STAKES`` lets an operator force the
    consequential branch (block + escalate) for an agent whose decisions are
    never safe to auto-proceed. Default off — the per-question signal wins.
    """
    raw = os.environ.get("BRIDGE_ASKUSERQUESTION_HIGH_STAKES", "").strip().lower()  # noqa: iso-helper-boundary — os.environ (.environ) false-matches the .env boundary pattern; this is a fallback-branch toggle, not an isolated runtime artifact
    return raw in {"1", "true", "yes", "on"}


# Substrings (case-insensitive) in the question/header that flag a
# consequential decision whose timeout must NOT be silently auto-proceeded.
# Conservative on purpose: a false "high-stakes" classification only costs a
# block+escalation (safe), while a false "low-stakes" classification could
# auto-proceed an irreversible action. When in doubt we still default to the
# reversible branch unless one of these markers (or the env default) fires —
# the agent itself can flag a question consequential by wording it with these.
_HIGH_STAKES_MARKERS = (
    "delete",
    "drop ",
    "irreversible",
    "production",
    "deploy",
    "force-push",
    "force push",
    "destroy",
    "wipe",
    "overwrite",
    "rm -rf",
    "merge to main",
    "push to main",
    "rotate",
    "revoke",
    "charge",
    "payment",
    "high-stakes",
    "high stakes",
    "consequential",
)


def is_high_stakes(question_text: str, *, explicit: bool | None = None) -> bool:
    """Decide whether a timeout should block+escalate (vs proceed+note).

    *explicit* overrides everything when not None (the tool input may carry an
    explicit consequential flag). Otherwise the operator env default OR any
    high-stakes marker in the question text selects the block branch.
    """
    if explicit is not None:
        return bool(explicit)
    if _high_stakes_env_default():
        return True
    lowered = question_text.lower()
    return any(marker in lowered for marker in _HIGH_STAKES_MARKERS)


def _coerce_options(raw_options: Any) -> list[str]:
    """Normalize the AskUserQuestion options into a flat list of labels.

    Claude Code's tool input has historically shaped options as a list of
    strings, a list of ``{"label": ...}`` dicts, or nested under per-question
    groups. Be permissive: accept strings, ``label``/``optionLabel``/``text``
    dict keys, and recurse one level into lists.
    """
    labels: list[str] = []

    def _add(item: Any) -> None:
        if item is None:
            return
        if isinstance(item, str):
            text = item.strip()
            if text:
                labels.append(text)
            return
        if isinstance(item, dict):
            for key in ("label", "optionLabel", "text", "value", "title"):
                value = item.get(key)
                if isinstance(value, str) and value.strip():
                    labels.append(value.strip())
                    return
            return
        if isinstance(item, (list, tuple)):
            for sub in item:
                _add(sub)

    if isinstance(raw_options, (list, tuple)):
        for opt in raw_options:
            _add(opt)
    else:
        _add(raw_options)
    return labels


def extract_question(tool_input: dict[str, Any]) -> tuple[str, list[str]]:
    """Pull a human-readable question + its option labels from the tool input.

    AskUserQuestion has shipped a few input shapes; cover the common ones:

    - ``{"questions": [{"question": "...", "header": "...",
       "options": [...]}]}`` (current multi-question array form)
    - ``{"question": "...", "options": [...]}`` (flat form)
    - a bare ``{"prompt": "..."}`` fallback.

    Returns ``(question_text, option_labels)``. Multiple questions are joined
    with their headers so the whole prompt reaches the channel.
    """
    questions = tool_input.get("questions")
    if isinstance(questions, list) and questions:
        chunks: list[str] = []
        options: list[str] = []
        for q in questions:
            if not isinstance(q, dict):
                continue
            header = str(q.get("header") or q.get("title") or "").strip()
            text = str(q.get("question") or q.get("prompt") or "").strip()
            line = " — ".join(part for part in (header, text) if part)
            if line:
                chunks.append(line)
            options.extend(_coerce_options(q.get("options")))
        question_text = "\n".join(chunks).strip()
        if question_text:
            return question_text, options

    for key in ("question", "prompt", "text"):
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip(), _coerce_options(tool_input.get("options"))

    # Last resort: serialize whatever we got so the human channel still sees
    # something actionable rather than an empty escalation.
    return (
        json.dumps(tool_input, ensure_ascii=False, sort_keys=True)[:2000],
        _coerce_options(tool_input.get("options")),
    )


def render_channel_question(question_text: str, options: list[str]) -> str:
    """Format the question + numbered options for the human channel."""
    lines = [question_text.strip()]
    if options:
        lines.append("")
        lines.append("Options:")
        for idx, label in enumerate(options, start=1):
            lines.append(f"  {idx}. {label}")
        lines.append("")
        lines.append(
            "Reply with the option number or its exact text to answer; "
            "no reply within the wait window triggers the autonomous fallback."
        )
    return "\n".join(lines).strip()


def reply_file_path(agent: str, state_dir: Path) -> Path:
    """Canonical reply-file the human channel / operator writes the answer to.

    One slot per agent under the agent's runtime state dir. The channel router
    (or the operator manually) writes ``{"answer": "<chosen option>"}`` (or a
    bare line of text) here; this module polls it and removes it once read so a
    stale answer can never satisfy a later question.
    """
    return state_dir / "agents" / agent / "askuserquestion-reply.json"


def _read_reply(path: Path) -> str | None:
    """Return the human's answer from *path*, or None if absent/empty.

    Accepts either a JSON object with an ``answer``/``reply``/``choice`` key or
    a bare text body. Returns None on any read/parse error so a malformed reply
    file degrades to "no answer" (→ fallback) rather than a hang or crash.
    """
    try:
        raw = path.read_text(errors="replace").strip()
    except OSError:
        return None
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except ValueError:
        return raw  # bare text answer
    if isinstance(parsed, dict):
        for key in ("answer", "reply", "choice", "option", "text"):
            value = parsed.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        return None
    if isinstance(parsed, str) and parsed.strip():
        return parsed.strip()
    return None


def _clear_reply(path: Path) -> None:
    try:
        path.unlink()
    except OSError:
        pass


def _post_escalation(
    *,
    agent: str,
    channel_question: str,
    timeout: int,
    subprocess_timeout: float,
    script_dir: Path,
    reply_path: Path,
) -> bool:
    """Fire ``agb escalate question`` for the rendered prompt.

    Returns True when the escalation command exited 0 (queued / dynamic-agent
    no-op both count as "delivered to the right surface"). A non-zero exit or a
    missing escalate script is non-fatal — the bounded wait + fallback still
    run, so the agent never hangs even when the channel route is unavailable.

    *subprocess_timeout* is the hard ceiling for THIS subprocess and is a slice
    of the overall wait budget (set by the caller against the single deadline),
    so a wedged notify can never push the total wall-clock past
    ``BRIDGE_ASKUSERQUESTION_WAIT_SECONDS`` (codex #1569 r1 finding 2).
    """
    escalate = script_dir / "bridge-escalate.sh"
    if not escalate.is_file():
        return False
    if subprocess_timeout <= 0:
        # No budget left for the escalation — skip it; the fallback still fires.
        return False
    context = (
        "Bounded AskUserQuestion escalation (#1569). The agent paused on an "
        "interactive multiple-choice prompt; it will wait up to "
        f"{timeout}s for a channel reply, then take an autonomous fallback. "
        f"Write the chosen option to: {reply_path}"
    )
    cmd = [
        "bash",
        str(escalate),
        "question",
        "--agent",
        agent,
        "--question",
        channel_question,
        "--context",
        context,
        "--wait-seconds",
        str(timeout),
    ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=subprocess_timeout,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    return proc.returncode == 0


def resolve_escalation(
    tool_input: dict[str, Any],
    *,
    agent: str,
    state_dir: Path,
    script_dir: Path,
    now: Any = time.monotonic,
    sleep: Any = time.sleep,
) -> dict[str, Any]:
    """Run the full bounded escalation and return the hook decision payload.

    The returned dict always carries:
      - ``decision``: ``answered`` | ``proceed_with_note`` | ``blocked``
      - ``reason``: human-readable guidance the hook surfaces to the agent
      - ``waited_seconds``: actual bounded wall-clock spent waiting
      - ``answer``: the chosen option (only on ``answered``)
      - ``high_stakes``: bool (only meaningful on a timeout)

    *now* / *sleep* are injectable so the smoke can drive the clock without a
    real 30s wall-clock wait.
    """
    timeout = wait_seconds()
    question_text, options = extract_question(tool_input)
    channel_question = render_channel_question(question_text, options)

    explicit_flag = tool_input.get("high_stakes")
    if explicit_flag is None:
        explicit_flag = tool_input.get("consequential")
    high_stakes = is_high_stakes(
        question_text,
        explicit=bool(explicit_flag) if explicit_flag is not None else None,
    )

    reply_path = reply_file_path(agent, state_dir)
    # Drop any stale answer left from a previous question before we escalate, so
    # the poll below cannot satisfy this question with a prior reply.
    _clear_reply(reply_path)
    reply_path.parent.mkdir(parents=True, exist_ok=True)

    # Single deadline = the WHOLE budget. The escalation subprocess AND the
    # reply poll both spend against it, so total wall-clock can never exceed
    # `timeout` no matter how slow the escalate notify is (codex #1569 r1
    # finding 2). The escalation gets at most a third of the window (capped at
    # 20s) so a working channel route still fires promptly while a wedged one
    # leaves the bulk of the window for an actual human reply.
    deadline = now() + timeout
    escalate_budget = min(20.0, max(0.0, timeout / 3.0))
    escalated = _post_escalation(
        agent=agent,
        channel_question=channel_question,
        timeout=timeout,
        subprocess_timeout=escalate_budget,
        script_dir=script_dir,
        reply_path=reply_path,
    )

    answer: str | None = None
    while True:
        answer = _read_reply(reply_path)
        if answer is not None:
            break
        remaining = deadline - now()
        if remaining <= 0:
            break
        sleep(min(POLL_INTERVAL_SECONDS, remaining))

    waited = max(0.0, timeout - max(0.0, deadline - now()))

    if answer is not None:
        _clear_reply(reply_path)
        return {
            "decision": "answered",
            "answer": answer,
            "reason": (
                f"A human answered your question via the channel: {answer!r}. "
                "Proceed with that choice."
            ),
            "waited_seconds": round(waited, 2),
            "escalated": escalated,
        }

    if high_stakes:
        return {
            "decision": "blocked",
            "reason": (
                "No human reply within the "
                f"{timeout}s window and this question is high-stakes / "
                "consequential. Do NOT guess. Set this task to `blocked` "
                "(agb done/block with a clear note) — the question was already "
                "escalated to the human channel for follow-up."
            ),
            "waited_seconds": round(waited, 2),
            "high_stakes": True,
            "escalated": escalated,
        }

    return {
        "decision": "proceed_with_note",
        "reason": (
            "No human reply within the "
            f"{timeout}s window. This question is reversible / low-stakes, so "
            "proceed with your best-judgment default and leave a durable note "
            "(in your output and any relevant task) describing the choice you "
            "made and that it can be course-corrected. Do NOT call "
            "AskUserQuestion again for the same decision."
        ),
        "waited_seconds": round(waited, 2),
        "high_stakes": False,
        "escalated": escalated,
    }
