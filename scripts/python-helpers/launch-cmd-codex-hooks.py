#!/usr/bin/env python3
"""Inject required Codex feature flags into a Codex launch command.

Extracted from `lib/bridge-state.sh::bridge_codex_launch_with_hooks` as
part of issue #835 (Wave A). The previous in-line Python body was read
through bash stdin redirection; on Homebrew Bash 5.3.9 that read can
wedge in `heredoc_write` when the wrapper is invoked inside a command
substitution from an absolute-path-sourced shell — the same class that
closed #800 / #815 / #827 / #840 for the daemon, CLI, status, and
session-id hot paths. Living in a real script bypasses the bash read
entirely. (Forbidden pattern strings intentionally omitted from this
comment so the footgun #11 self-audit grep recipe does not flag a
textual mention as a real callsite.)

Args (positional, order-sensitive):
    sys.argv[1] — original launch_cmd string (env prefix + `codex …`)

Stdout: the rewritten launch_cmd with `hooks` and `fast_mode`
features pinned via `-c features.<name>=true`. Idempotent: an
already-pinned flag (via `--enable <name>` or any `-c features.<name>=…`
form) is left alone. Always exits 0.

Legacy alias convergence:
    codex-cli 0.135.0 renamed the `[features]` flag `codex_hooks` → `hooks`
    and silently-deprecated the old name (`codex -c features.codex_hooks=true`
    still works but prints "[features].codex_hooks is deprecated. Use
    [features].hooks instead."). Because this helper re-materializes the
    launch_cmd on EVERY wake, it actively rewrites any present legacy
    `features.codex_hooks=true` / `--enable codex_hooks` token to the new
    `hooks` name before the inject check runs. That converges already-rostered
    codex agents to the warning-free flag on their next wake without a
    destructive roster rewrite. The invariant after this helper runs: exactly
    one `features.hooks=true` and zero `features.codex_hooks=true`, for the
    legacy-present / new-present / neither input shapes, and running it twice
    yields the same output. NOTE: this targets ONLY the `[features]` CLI flag —
    it is unrelated to agent-bridge's own Codex hooks.json file surface
    (SessionStart/Stop/PreToolUse wiring), which keeps the `codex_hooks` name.

Behavior (preserved from the pre-extraction body):
    v0.8.6 hotfix: this helper ensures BOTH `hooks` (formerly `codex_hooks`)
    and `fast_mode` are pinned on every codex launch — admin-pair backfill,
    isolated agent create, v0.7→v0.8 migration, and resume paths all
    converge through here. Pre-hotfix it only injected the hooks feature,
    so an existing roster with the legacy default launch_cmd (no
    fast_mode) silently fell off the fast inference path on every wake.
"""

import re
import shlex
import sys


REQUIRED_FEATURES = ("hooks", "fast_mode")
ARG_TAKING_FLAGS = {
    "-c", "--enable", "--disable", "--profile", "-p",
    "--model", "-m", "--cd", "-C",
}

# codex-cli 0.135.0 renamed these `[features]` flags. Key is the deprecated
# name (which still works but prints a deprecation warning); value is the new
# canonical name. We actively rewrite any present legacy token to the new name
# during re-materialization so already-rostered agents stop warning next wake.
LEGACY_FEATURE_ALIASES = {
    "codex_hooks": "hooks",
}


def rewrite_legacy_feature_aliases(rest: list[str]) -> list[str]:
    """Rewrite any deprecated `[features]` flag token to its new canonical name.

    Handles both the `--enable <legacy>` form and the
    `-c features.<legacy>=<value>` form. Other tokens are preserved exactly.
    Idempotent: a launch_cmd already on the new name passes through untouched.
    """
    out: list[str] = []
    i = 0
    while i < len(rest):
        token = rest[i]
        next_value = rest[i + 1] if i + 1 < len(rest) else None
        if (
            token == "--enable"
            and next_value is not None
            and next_value in LEGACY_FEATURE_ALIASES
        ):
            out.append(token)
            out.append(LEGACY_FEATURE_ALIASES[next_value])
            i += 2
            continue
        if token == "-c" and next_value is not None:
            rewritten = next_value
            for legacy, new in LEGACY_FEATURE_ALIASES.items():
                rewritten = rewritten.replace(
                    f"features.{legacy}=", f"features.{new}="
                )
            out.append(token)
            out.append(rewritten)
            i += 2
            continue
        out.append(token)
        i += 1
    return out


def dedupe_feature_enablement(rest: list[str], feature: str) -> list[str]:
    """Keep only the FIRST enablement of `feature`, dropping later duplicates.

    Canonicalizing a legacy alias to its new name (above) can collapse two
    distinct tokens (e.g. legacy `features.codex_hooks=true` + an already-new
    `features.hooks=true`, or `--enable codex_hooks` + `--enable hooks`) onto
    the same feature, leaving two enablements of the same canonical name. This
    pass removes the surplus so the invariant "exactly one enablement of the
    feature" holds. Only the recognized enablement spellings for this feature
    are de-duplicated; every other token (including unrelated `-c key=val`
    pairs) is preserved exactly and in order.
    """
    enable_pattern = f"features.{feature}=true"
    out: list[str] = []
    seen = False
    i = 0
    while i < len(rest):
        token = rest[i]
        next_value = rest[i + 1] if i + 1 < len(rest) else None
        is_enable = token == "--enable" and next_value == feature
        is_config = (
            token == "-c"
            and next_value is not None
            and enable_pattern in next_value
        )
        if is_enable or is_config:
            if seen:
                i += 2  # surplus enablement — drop both flag and value
                continue
            seen = True
            out.append(token)
            out.append(next_value)
            i += 2
            continue
        out.append(token)
        i += 1
    return out


def has_feature(rest: list[str], feature: str) -> bool:
    pattern = f"features.{feature}=true"
    i = 0
    while i < len(rest):
        token = rest[i]
        next_value = rest[i + 1] if i + 1 < len(rest) else None
        if token == "--enable" and next_value == feature:
            return True
        if token == "-c" and next_value is not None and pattern in next_value:
            return True
        i += 2 if token in ARG_TAKING_FLAGS and next_value is not None else 1
    return False


def main() -> int:
    original = sys.argv[1]
    # The launch_cmd this helper rewrites is always either a bare `codex …`
    # invocation or an env-assignment-prefixed one (`FOO=bar BAZ=qux codex …`),
    # matching how lib/bridge-state.sh builds it (`bridge_build_resume_launch_cmd`
    # treats the leading `^([A-Z_]+=[^ ]+\s+)+` run as the env prefix). Require
    # the prefix to be exactly zero or more `NAME=value` assignments so that a
    # non-codex command that merely *contains* the word `codex` — whether inside
    # another token (`notcodex`) or as an argument (`echo codex`, `wrapper codex
    # …`) — is left untouched instead of having feature flags injected into it.
    match = re.match(
        r"^(?P<prefix>(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*)"
        r"(?P<command>codex(?:\s|$).*)$",
        original,
    )
    if not match:
        print(original)
        return 0

    env_prefix = match.group("prefix")
    args = shlex.split(match.group("command"))
    if not args or args[0] != "codex":
        print(original)
        return 0

    # Converge any deprecated feature flag (e.g. legacy `codex_hooks`) to its
    # new canonical name FIRST, so a roster that still carries the old token
    # stops emitting the deprecation warning and the inject check below does
    # not double-pin the same feature under both names.
    rest = rewrite_legacy_feature_aliases(args[1:])
    # Canonicalization can collapse a legacy + already-new token (or duplicate
    # legacy tokens) onto the same feature, and a hand-edited roster may carry a
    # required flag twice; drop the surplus so each required feature is enabled
    # exactly once before we decide what (if anything) to inject.
    for feature in REQUIRED_FEATURES:
        rest = dedupe_feature_enablement(rest, feature)
    prefix_pairs: list[str] = []
    for feature in REQUIRED_FEATURES:
        if not has_feature(rest, feature):
            prefix_pairs.extend(["-c", f"features.{feature}=true"])

    if prefix_pairs:
        rest = [*prefix_pairs, *rest]

    quoted = " ".join(shlex.quote(token) for token in [args[0], *rest])
    print(f"{env_prefix}{quoted}" if env_prefix else quoted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
