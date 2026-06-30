#!/usr/bin/env python3
"""Value-screen assertions for #2024 B: the BRIDGE_A2A_ROOM_AUTOJOIN flag_bool
type canonicalizes on/off spellings to "1"/"0" and rejects everything else.

Standalone helper (invoked by v0166-lc-config-set-env.sh with the bridge-config.py
path as argv[1]) so the value screen is exercised directly — the wrapper's
negative tests deny at the caller-trust gate before value validation runs. Kept
out of a heredoc-stdin subprocess per the lint-heredoc-ban contract.

Exit 0 on all assertions passing; non-zero with a diagnostic on the first miss.
"""
import importlib.util
import sys

KEY = "BRIDGE_A2A_ROOM_AUTOJOIN"


def _fail(msg: str) -> None:
    print(f"valuecheck FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    if len(sys.argv) < 2:
        _fail("usage: valuecheck.py <path-to-bridge-config.py>")
    cfg_path = sys.argv[1]
    spec = importlib.util.spec_from_file_location("bridge_config_valuecheck", cfg_path)
    if spec is None or spec.loader is None:
        _fail(f"could not load module spec from {cfg_path!r}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    validate = mod.validate_env_value

    # The autojoin key must be typed flag_bool (not flag_one) so "0" is durable.
    if mod.ENV_KEY_ALLOWLIST.get(KEY) != mod.ENV_KEY_TYPE_FLAG_BOOL:
        _fail(f"{KEY} must be typed flag_bool, got {mod.ENV_KEY_ALLOWLIST.get(KEY)!r}")

    # ON spellings canonicalize to "1".
    for raw in ("1", "true", "on", "yes", "TRUE", " On ", "YES"):
        val, err = validate(KEY, raw)
        if err is not None or val != "1":
            _fail(f"on-spelling {raw!r} should canonicalize to '1', got ({val!r}, {err!r})")

    # OFF spellings canonicalize to "0" (the durable opt-out).
    for raw in ("0", "false", "off", "no", "disable", "disabled", " OFF ", "No"):
        val, err = validate(KEY, raw)
        if err is not None or val != "0":
            _fail(f"off-spelling {raw!r} should canonicalize to '0', got ({val!r}, {err!r})")

    # Garbage / ambiguous values are rejected (no loose prefixes, no truthy noise).
    for raw in ("2", "tru", "onn", "enable", "enabled", "yep", "", "  "):
        val, err = validate(KEY, raw)
        if val is not None or err is None:
            _fail(f"garbage value {raw!r} must be rejected, got ({val!r}, {err!r})")

    # Control-char / newline smuggling is rejected BEFORE typing (defense-in-depth).
    for raw in ("1\n", "0\x00", "on\r", "off\t"):
        val, err = validate(KEY, raw)
        if val is not None or err is None:
            _fail(f"control-char value {raw!r} must be rejected, got ({val!r}, {err!r})")

    print("valuecheck OK: flag_bool canonicalization + rejection assertions held")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
