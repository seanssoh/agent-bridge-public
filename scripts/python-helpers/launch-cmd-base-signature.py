#!/usr/bin/env python3
"""launch-cmd-base-signature.py — derive a launch command's *stable base
signature* and decide whether a recorded crash launch command is STALE
relative to the agent's current launch command (issue #2063).

Background
----------
A leftover ``runtime/crash/report`` env file from a PRIOR launch era keeps
driving false crash-loop alarms on a HEALTHY agent after the agent's
launch command changes (dynamic→static convert, ``reclassify``,
``update --set-launch-cmd``, or a manual launch change). The daemon
re-reads that report env file every sweep and re-emits the crash audit with no
awareness that the recorded ``CRASH_LAUNCH_CMD`` no longer matches the
agent's current launch command — i.e. the crash predates the current
launch and is stale.

This helper is the comparison primitive the daemon staleness guard uses.
It is shell-token based (NOT byte-prefix), because the resolved launch
command interleaves volatile session state non-contiguously: the static
Claude builder reconstructs the token list as
``claude [--resume <id>|--continue] --dangerously-skip-permissions
--name <a> <extras>`` and can reorder managed flags, so a raw prefix
check would falsely retire a real same-launch crash loop.

Stable base signature
----------------------
Tokenize with ``shlex.split`` (no ``eval``), collapse quoting/whitespace,
then strip ONLY the bridge-generated volatile session tokens so two
launches of the SAME configured base reduce to the same signature even
when the resume id rotates between the crash and the next daemon sweep:

  Claude:
    - ``--resume <id>``        (and ``--resume=<id>``)
    - ``--continue``
    - ``-c`` ONLY when the parsed executable is ``claude`` (Claude's
      bare continue flag). Codex's ``-c features.hooks=true`` is stable
      config and is PRESERVED.
  Codex:
    - ``codex resume <id>`` and ``codex resume --last`` reduce to
      ``codex`` (the resume verb + its target are session state).

Operator flags (``--model``, ``--effort``, ``--dangerously-*``,
``--channels``, an env-prefix, etc.) are NOT stripped — they are part of
the configured launch base and a deliberate change to them is a real
launch-base change, not session noise.

Staleness predicate (fail-safe by construction)
-----------------------------------------------
``stale <recorded> <current>`` exits:
  0  STALE      — both signatures are present AND non-degenerate AND the
                  current base signature is NOT a multiset subset of the
                  recorded one (positive evidence the recorded launch was
                  built from a DIFFERENT base). Containment is ORDER-
                  INDEPENDENT because the static-Claude builder canonicalizes
                  flag order; see `_multiset_subset`.
  1  NOT-STALE  — every current base token is present in the recorded one
                  with at least the same multiplicity (same launch era → a
                  matching crash must still alarm).
  2  INCOMPARABLE — cannot prove a mismatch, so the caller MUST keep
                  alarming. Covers: either side empty/unparseable; a
                  signature that degenerates to only the bare engine
                  token (``claude`` / ``codex``) after stripping; a
                  cross-engine pair (different engine entirely is treated
                  as incomparable here — the daemon never relaunches a
                  crashed agent under a different engine without an
                  explicit reclassify that itself clears state, and we
                  prefer to NEVER silently drop a real crash signal).

The daemon retires the stale report ONLY on exit 0 (positive evidence).
Every other outcome keeps the existing alarm path intact.

Two comparison modes (the daemon prefers `equal`, falls back to `stale`):
  - ``equal`` — SYMMETRIC raw-base-vs-raw-base. Both sides are the operator's
    literal roster base (recorded ``CRASH_LAUNCH_CMD_RAW`` vs the current
    ``bridge_agent_launch_cmd_raw``), so an exact multiset equality detects an
    added / removed / changed base flag in BOTH directions. This is the
    accurate path and the one the daemon uses whenever the report carries the
    raw base (#2063 r2: a resolved-vs-raw compare cannot tell a roster-injected
    flag from a base removal).
  - ``stale`` — ASYMMETRIC resolved-vs-raw containment, the LEGACY fallback for
    a pre-fix report env file that has no ``CRASH_LAUNCH_CMD_RAW``. The recorded
    value is the RESOLVED cmd (with the static builder's injected flags), so
    only a fail-safe one-directional containment is sound (it never
    false-retires a roster-injected same-launch).

CLI (file-as-argv, no heredoc-stdin — footgun #11 / KNOWN_ISSUES.md §26):
    launch-cmd-base-signature.py signature <launch-cmd>
        → prints the space-joined stable base signature (may be empty).
    launch-cmd-base-signature.py stale <recorded-resolved-cmd> <current-raw-cmd>
        → exit 0/1/2 (asymmetric resolved-vs-raw containment).
    launch-cmd-base-signature.py equal <recorded-raw-cmd> <current-raw-cmd>
        → exit 0/1/2 (symmetric raw-base equality).
"""

import shlex
import sys
from collections import Counter

# Claude volatile flags that carry session/continue state (NOT base config).
_CLAUDE_VOLATILE_VALUE_FLAGS = ("--resume",)
_CLAUDE_VOLATILE_BARE_FLAGS = ("--continue", "-c")


def _parse(value):
    """Tokenize a launch command. Returns (env_prefix_tokens, argv_tokens)
    or None when the command cannot be parsed / has no executable.

    The leading run of ``KEY=VALUE`` tokens is the env prefix; the first
    non-assignment token is the executable. Parsing matches the rest of
    the launch-cmd helper family (shlex, no eval)."""
    if not value or not value.strip():
        return None
    try:
        tokens = shlex.split(value)
    except ValueError:
        return None
    if not tokens:
        return None
    env_prefix = []
    idx = 0
    while idx < len(tokens):
        tok = tokens[idx]
        if tok.startswith("-"):
            break
        eq = tok.find("=")
        if eq <= 0:
            break
        key = tok[:eq]
        if not key[0].isalpha() and key[0] != "_":
            break
        if not all(c.isalnum() or c == "_" for c in key):
            break
        env_prefix.append(tok)
        idx += 1
    argv = tokens[idx:]
    if not argv:
        return None
    return env_prefix, argv


def raw_signature(value):
    """Return the FULL normalized token list of a RAW roster base launch cmd
    (env prefix + entire argv), with NO volatile-token stripping and NO
    degenerate-collapse.

    Used ONLY for the symmetric `equal` mode (recorded ``CRASH_LAUNCH_CMD_RAW``
    vs the current ``bridge_agent_launch_cmd_raw``). A raw roster base is the
    operator's literal ``BRIDGE_AGENT_LAUNCH_CMD`` string: it NEVER carries the
    bridge-injected ``--resume <id>`` (that is added only at resolve time), so
    there is nothing volatile to strip — and ``--continue`` / ``-c`` ARE
    operator configuration here (continue-vs-fresh intent), so they MUST be
    compared, not dropped. ``shlex`` is used to normalize quoting/whitespace
    only. Returns [] only when the command is empty/unparseable (→ incomparable
    upstream)."""
    parsed = _parse(value)
    if parsed is None:
        return []
    env_prefix, argv = parsed
    return list(env_prefix) + list(argv)


def base_signature(value):
    """Return the stable base signature token list for a launch command.

    Empty list means "no meaningful signature" (unparseable, or the
    signature degenerated to only the bare engine token after stripping
    volatile session state — the caller treats that as incomparable)."""
    parsed = _parse(value)
    if parsed is None:
        return []
    env_prefix, argv = parsed
    exe = argv[0]

    sig = list(env_prefix)

    if exe == "codex":
        # ``codex resume <id>`` / ``codex resume --last`` → ``codex``.
        rest = argv[1:]
        if rest and rest[0] == "resume":
            rest = rest[1:]
            # Drop the resume target: ``--last`` or a bare session id.
            if rest and (rest[0] == "--last" or not rest[0].startswith("-")):
                rest = rest[1:]
        sig.append("codex")
        sig.extend(rest)
    elif exe == "claude":
        sig.append("claude")
        i = 1
        while i < len(argv):
            tok = argv[i]
            base = tok.split("=", 1)[0]
            if base in _CLAUDE_VOLATILE_VALUE_FLAGS:
                # ``--resume <id>`` (space form) or ``--resume=<id>``.
                if "=" in tok:
                    i += 1
                else:
                    i += 2 if i + 1 < len(argv) else 1
                continue
            if tok in _CLAUDE_VOLATILE_BARE_FLAGS:
                i += 1
                continue
            sig.append(tok)
            i += 1
    else:
        # Unknown engine / arbitrary operator command: keep argv verbatim
        # (env prefix + full argv). No volatile-token assumptions.
        sig.extend(argv)

    # Degenerate: nothing left but the bare engine token (or empty). The
    # caller treats this as "incomparable" — too little signal to prove a
    # base change without risking a false retire of a real crash loop.
    if not sig:
        return []
    if len(sig) == 1 and sig[0] in ("claude", "codex"):
        return []
    return sig


def _multiset_subset(needle, haystack):
    """True if every token of ``needle`` appears in ``haystack`` at least as
    many times (multiset / counting-bag containment), ORDER-INDEPENDENT.

    Containment must be order-independent, NOT an ordered subsequence: the
    static-Claude builder CANONICALIZES flag order
    (``launch-cmd-static-claude-build.py`` reconstructs
    ``claude [resume] --dangerously-skip-permissions --name <a> --model …
    --effort … <extras>``), so the recorded RESOLVED cmd does not preserve
    the operator's authored order from the raw roster base. An ordered
    subsequence test would FALSE-RETIRE a real same-launch crash whenever the
    operator authored, e.g., ``--model x --effort y
    --dangerously-skip-permissions`` (raw) while the builder emits
    ``--dangerously-skip-permissions … --model x --effort y`` (recorded) — the
    raw ``--dangerously-skip-permissions`` then sorts AFTER ``--model`` /
    ``--effort`` in the recorded cmd and the ordered check reports a spurious
    mismatch (codex review #2063). Multiplicity is honored so a genuinely
    added / removed / changed base flag (a true launch-base change) is still
    detected as stale."""
    have = Counter(haystack)
    for tok, count in Counter(needle).items():
        if have[tok] < count:
            return False
    return True


def _stale(recorded, current):
    """Return the staleness exit code (0 stale / 1 not-stale / 2 incomparable)."""
    rec_sig = base_signature(recorded)
    cur_sig = base_signature(current)
    if not rec_sig or not cur_sig:
        return 2
    # Cross-engine: the executable differs entirely. Treat as incomparable
    # (keep alarming) rather than asserting staleness — never silently drop
    # a real crash signal on an ambiguous engine transition.
    rec_exe = next((t for t in rec_sig if not _looks_like_env(t)), None)
    cur_exe = next((t for t in cur_sig if not _looks_like_env(t)), None)
    if rec_exe != cur_exe:
        return 2
    # Order-independent containment: the current configured base is still
    # reflected in the recorded resolved cmd ⇒ same launch era ⇒ NOT stale.
    if _multiset_subset(cur_sig, rec_sig):
        return 1
    return 0


def _equal(recorded, current):
    """SYMMETRIC base-equality staleness (0 stale / 1 not-stale / 2 incomparable).

    Used when BOTH sides are the operator-configured ROSTER BASE (the recorded
    `CRASH_LAUNCH_CMD_RAW` vs the current `bridge_agent_launch_cmd_raw`). Both
    are the operator's literal launch cmd, so we compare the FULL raw token set
    (``raw_signature`` — NO volatile stripping; ``--continue`` / ``-c`` are
    operator config here, and a raw base never carries an injected
    ``--resume <id>``). An exact multiset equality correctly detects an ADDED,
    REMOVED, or CHANGED base flag — in BOTH directions — as STALE (codex #2063
    r2: the asymmetric resolved-vs-raw containment could not catch a REMOVAL),
    while an identical base (incl. a pure reorder) is NOT stale. Order-
    independent (`Counter` equality). Incomparable (2) only when a side is
    empty/unparseable (e.g. a dynamic agent with no roster base)."""
    rec_sig = raw_signature(recorded)
    cur_sig = raw_signature(current)
    if not rec_sig or not cur_sig:
        return 2
    rec_exe = next((t for t in rec_sig if not _looks_like_env(t)), None)
    cur_exe = next((t for t in cur_sig if not _looks_like_env(t)), None)
    if rec_exe != cur_exe:
        return 2
    if Counter(rec_sig) == Counter(cur_sig):
        return 1
    return 0


def _looks_like_env(tok):
    eq = tok.find("=")
    if eq <= 0:
        return False
    key = tok[:eq]
    return (key[0].isalpha() or key[0] == "_") and all(
        c.isalnum() or c == "_" for c in key
    )


def _main(argv):
    if len(argv) < 2:
        print("usage: launch-cmd-base-signature.py <signature|stale|equal> ...",
              file=sys.stderr)
        return 3
    mode = argv[1]
    if mode == "signature":
        if len(argv) != 3:
            print("usage: launch-cmd-base-signature.py signature <launch-cmd>",
                  file=sys.stderr)
            return 3
        print(" ".join(base_signature(argv[2])))
        return 0
    if mode == "stale":
        if len(argv) != 4:
            print("usage: launch-cmd-base-signature.py stale "
                  "<recorded-resolved-cmd> <current-raw-cmd>", file=sys.stderr)
            return 3
        return _stale(argv[2], argv[3])
    if mode == "equal":
        if len(argv) != 4:
            print("usage: launch-cmd-base-signature.py equal "
                  "<recorded-raw-cmd> <current-raw-cmd>", file=sys.stderr)
            return 3
        return _equal(argv[2], argv[3])
    print(f"launch-cmd-base-signature.py: unknown mode: {mode}", file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
