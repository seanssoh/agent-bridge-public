#!/usr/bin/env python3
# scripts/smoke/1691-credential-mention-intent-revert.py — build a copy of
# hooks/tool-policy.py with the issue #1691 intent-aware credential/alias
# mention gates REVERTED to the pre-#1691 blunt-substring behavior.
#
# Used by scripts/smoke/1691-credential-mention-intent.sh as the GENUINE
# revert-teeth: every ALLOW case the fix unblocks must flip to DENY against
# this reverted copy, proving the relaxation (and nothing else) produces the
# ALLOW verdicts.
#
# Strategy: append helper-override definitions at module scope (a later `def`
# shadows the earlier one) so the four intent-aware helpers fall back to the
# blunt-substring semantics, AND patch the two inline gate sites (the Stage A
# argv-aware shared-forbidden check and the Stage B class relaxation +
# message-body shortcut) back to their pre-#1691 shapes via anchored string
# replacement. Fail LOUD if any anchor is missing — a drifted hook must not
# silently produce a no-op revert that passes the teeth vacuously.

import sys


def _replace_once(src: str, old: str, new: str, label: str) -> str:
    count = src.count(old)
    if count != 1:
        sys.stderr.write(
            f"revert: anchor '{label}' found {count} times (want 1)\n"
        )
        sys.exit(3)
    return src.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: 1691-...-revert.py <src> <dest>\n")
        return 2
    src_path, dest_path = sys.argv[1], sys.argv[2]
    src = open(src_path, encoding="utf-8").read()

    # --- Stage A: the call site is `if _bash_argv_targets_shared_forbidden(
    # text): return <deny>`. The helper override appended below restores the
    # blunt `forbidden_alias in text` substring semantics, so the call site
    # then behaves exactly as the pre-#1691 deny — no call-site surgery needed.
    if "_bash_argv_targets_shared_forbidden(text)" not in src:
        sys.stderr.write("revert: stage-A call site signature drifted\n")
        return 3

    # --- Non-Bash: restore the uniform credential-marker deny on ALL keys
    # (file_path / path / pattern), i.e. apply `_raw_mentions_claude_creden-
    # tials` to the Grep `pattern` again (the pre-#1691 over-block). Replace
    # the #1691 pattern-split + credential_marker assignment with the original
    # single `if _raw_mentions_claude_credentials(raw):` guard.
    nonbash_new_start = '            if key == "pattern":\n'
    nonbash_anchor_end = (
        "            credential_marker = _raw_mentions_credential_value(\n"
        "                raw\n"
        "            ) or _raw_text_has_credential_filename(raw)\n"
        "            if credential_marker:\n"
    )
    i = src.find(nonbash_new_start)
    j = src.find(nonbash_anchor_end)
    if i == -1 or j == -1 or j < i:
        sys.stderr.write("revert: could not locate non-Bash pattern split\n")
        return 3
    j_end = j + len(nonbash_anchor_end)
    src = (
        src[:i]
        + "            if _raw_mentions_claude_credentials(raw):\n"
        + src[j_end:]
    )

    # --- Stage B: drop the #1691 message-body shortcut (restore pre-#1691).
    msgbody_block_start = (
        "    # Issue #1691: a peer alias that appears ONLY inside a "
        "`_STRING_PAYLOAD_"
    )
    msgbody_block_end = "    if not read_intent:"
    i = src.find(msgbody_block_start)
    j = src.find(msgbody_block_end, i if i != -1 else 0)
    if i == -1 or j == -1 or j < i:
        sys.stderr.write("revert: could not locate Stage B message-body shortcut\n")
        return 3
    src = src[:i] + src[j:]

    # --- Stage B: restore the class==system gate on the read-intent carve-out.
    src = _replace_once(
        src,
        "    if not read_intent:\n"
        '        return f"cross-agent access is blocked: {matched_alias}"\n'
        "\n"
        "    if _command_has_shell_embedding(text):",
        "    if not (read_intent and current_agent_class() == \"system\"):\n"
        '        return f"cross-agent access is blocked: {matched_alias}"\n'
        "\n"
        "    if _command_has_shell_embedding(text):",
        "stage-B class gate",
    )

    # --- Append helper overrides (blunt-substring fallbacks). A trailing def
    # at module scope shadows the earlier definition for every call site.
    overrides = (
        "\n\n"
        "# --- issue #1691 revert-teeth overrides (smoke only) ---------------\n"
        "# Restore the pre-#1691 blunt-substring behavior so the over-block\n"
        "# returns: the credential-FILENAME and shared-forbidden aliases deny\n"
        "# on mere textual mention again, and the string-payload subtraction in\n"
        "# the peer-home occurrence proof is disabled.\n"
        "def _raw_mentions_credential_value(raw):  # noqa: F811\n"
        "    return _raw_mentions_claude_credentials(raw)\n"
        "\n"
        "\n"
        "def _bash_argv_opens_credential_filename(text):  # noqa: F811\n"
        "    return _raw_text_has_credential_filename(text)\n"
        "\n"
        "\n"
        "def _bash_argv_targets_shared_forbidden(text):  # noqa: F811\n"
        "    return any(alias in text for alias in _shared_forbidden_aliases())\n"
        "\n"
        "\n"
        "def _string_payload_flag_values(text):  # noqa: F811\n"
        "    return []\n"
    )
    # Insert the overrides BEFORE the `if __name__ == \"__main__\"` entrypoint
    # so they are defined before `main()` runs when the copy is executed as a
    # subprocess (the smoke runs `python3 <reverted-hook> < payload`). Appending
    # after the entrypoint would define the overrides too late — `main()` would
    # already have called the original helpers (import-only shadowing != run).
    entrypoint = '\nif __name__ == "__main__":\n'
    idx = src.rfind(entrypoint)
    if idx == -1:
        sys.stderr.write("revert: could not locate __main__ entrypoint\n")
        return 3
    src = src[:idx] + "\n" + overrides + src[idx:]

    open(dest_path, "w", encoding="utf-8").write(src)
    return 0


if __name__ == "__main__":
    sys.exit(main())
