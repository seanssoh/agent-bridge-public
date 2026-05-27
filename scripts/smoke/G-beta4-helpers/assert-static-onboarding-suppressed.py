#!/usr/bin/env python3
"""G-beta4 T2 — static session_type suppresses onboarding_state in
the markdown render.

Usage:
  assert-static-onboarding-suppressed.py <md-file> <static-agent> <admin-agent>

Assertions:
  * The static agent's section appears in the markdown.
  * The static agent's section does NOT include an `- onboarding_state:`
    line (issue #1266: static session_type fields are noise — the
    template default is always `complete`).
  * The admin agent's section DOES include an `- onboarding_state:`
    line (the admin contract still surfaces the value).
"""
import re
import sys
from pathlib import Path

md_path, static_agent, admin_agent = sys.argv[1], sys.argv[2], sys.argv[3]
text = Path(md_path).read_text(encoding="utf-8")


def section_for(agent: str) -> str:
    """Return the markdown subsection for ``## <agent>`` up to the
    next ``## `` or end of file. Empty string when the agent is not
    present in the report.
    """
    pat = re.compile(rf"^## {re.escape(agent)}\n(.*?)(?=^## |\Z)", re.M | re.S)
    m = pat.search(text)
    return m.group(1) if m else ""


static_section = section_for(static_agent)
assert static_section, (
    f"FAIL: static agent '{static_agent}' section not found in markdown.\n"
    f"--- markdown ---\n{text}"
)
assert "- onboarding_state:" not in static_section, (
    f"FAIL: static session_type rows must NOT emit onboarding_state line "
    f"(noise per #1266). Found one in section:\n{static_section}"
)

admin_section = section_for(admin_agent)
assert admin_section, (
    f"FAIL: admin agent '{admin_agent}' section not found in markdown."
)
assert "- onboarding_state:" in admin_section, (
    f"FAIL: admin session_type rows MUST still emit onboarding_state line "
    f"(suppression is static-only). Section:\n{admin_section}"
)

print("T2 PASS")
