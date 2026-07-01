#!/usr/bin/env python3
"""Print the minimum required Node.js MAJOR version a plugin declares.

Reads a plugin's ``package.json`` (path given as argv[1]) and inspects its
optional ``engines.node`` semver range. Emits the smallest major version that
range accepts, on stdout, as a bare integer (e.g. ``14``). This is the leaf the
agent-start node-version gate (``bridge_warn_plugins_node_engines`` in
lib/bridge-channels.sh) uses to decide whether the host node is too old for a
to-be-loaded plugin.

Invoked file-as-argv (NOT heredoc-stdin) to avoid the Bash 5.3.9
``read_comsub``/``heredoc_write`` deadlock (footgun #11 / KNOWN_ISSUES.md §26).

Contract:
  * Missing file / unreadable / invalid JSON / not an object -> exit 1, print
    nothing. (The caller treats "no declared requirement" and "couldn't read"
    identically: it simply does not warn for that plugin. An unparseable
    manifest is not operator-actionable at start time — never block start.)
  * ``engines`` absent / not an object / ``engines.node`` absent / not a
    string -> exit 1, print nothing.
  * ``engines.node`` present but no numeric lower floor is derivable (e.g.
    ``"*"``, ``"x"``, ``"latest"``, an upper-bound-only ``"<21"``, garbage)
    -> exit 1, print nothing. A wildcard means "any version" — NO requirement,
    so the caller never warns for it.
  * A minimum major is derivable -> print it as a bare integer, exit 0.

Range handling (deliberately conservative — we only warn, never block, so a
missed warning is safer than a FALSE one):
  * A range is an ``||``-separated set of alternatives (an OR union — any one
    alternative being satisfied is enough for the plugin to run). The effective
    minimum is the SMALLEST major across the alternatives' floors. BUT if even
    one alternative has NO floor (a wildcard, or upper-bound-only), the whole
    union accepts every version -> NO requirement -> exit 1 (e.g. ``* || >=20``
    and ``<21 || >=18`` both exit 1, never warn).
  * Within one alternative, comparators are ANDed; the floor is the LARGEST
    lower-bound major among them (all must hold). Comparators are scanned as
    whole units, so an operator separated from its version by whitespace
    (``>= 16``) and a following upper bound (``< 21``) are read correctly:
    ``">= 16 < 21"`` floors at 16, not 21.
  * A hyphen range ``A - B`` (spaces required, per semver) floors at A's major.
  * Supported comparator shapes: ``>=14`` / ``>= 14``, ``>14``, ``=18`` /
    ``18`` / ``18.0.0``, ``^18``, ``~16``, ``18.x`` / ``18.*`` (the ``.x``
    suffix is ignored — the leading major is the floor). ``<`` / ``<=`` upper
    bounds and bare wildcard majors do not raise a floor.
  * ``>N.M.K`` conservatively floors at major N (not N+1) — we would rather
    under-warn than warn on a host that is actually fine.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# One comparator UNIT: an optional operator (which may be separated from
# its version by whitespace, e.g. ``>= 16``) followed by a version token
# whose leading numeric component is the major we care about. Matched
# globally across an alternative via re.finditer so ``>= 16 < 21`` yields
# two units (``>= 16`` and ``< 21``) rather than four whitespace tokens.
# A bare ``x``/``*``/``X`` major is a wildcard: it declares NO numeric
# floor (see _comparator_floor).
_COMPARATOR = re.compile(
    r"""(?P<op>>=|<=|>|<|\^|~|=)?     # optional comparator / range operator
        \s*
        v?                             # optional leading v
        (?P<major>\d+|[xX*])           # major component
        (?:\.[0-9xX*]+)*               # trailing .minor.patch (ignored)
    """,
    re.VERBOSE,
)

# Hyphen range: ``A - B`` (spaces REQUIRED per semver) means ``>= A``.
# The floor is A's major. Matched before per-unit scanning so the ``-``
# is not misread as anything else.
_HYPHEN_RANGE = re.compile(
    r"""^\s*
        v?(?P<low>\d+)(?:\.[0-9xX*]+)*   # low bound (its major is the floor)
        \s+-\s+
        v?[0-9xX*]+(?:\.[0-9xX*]+)*      # high bound (ignored for the floor)
        \s*$
    """,
    re.VERBOSE,
)


def _comparator_floor(op: str, raw_major: str) -> int | None:
    """Return the lower-bound major a single comparator unit establishes.

    None when the unit sets no numeric lower floor: upper-bound
    comparators (``<`` / ``<=``) and wildcard majors (``*`` / ``x`` /
    ``X``) — the latter meaning "any version", i.e. no requirement.
    """
    if op in ("<", "<="):
        return None
    if raw_major in ("x", "X", "*"):
        return None
    # >, >=, ^, ~, =, and a bare version all lower-bound at `major`.
    return int(raw_major)


def _alternative_floor(alt: str) -> int | None:
    """Return the floor major for one ``||`` alternative, or None."""
    alt = alt.strip()
    if not alt:
        return None

    # Hyphen range takes the low bound's major as the floor.
    hm = _HYPHEN_RANGE.match(alt)
    if hm:
        return int(hm.group("low"))

    floor: int | None = None
    for m in _COMPARATOR.finditer(alt):
        op = m.group("op") or "="
        unit_floor = _comparator_floor(op, m.group("major"))
        if unit_floor is None:
            continue
        if floor is None or unit_floor > floor:
            floor = unit_floor
    return floor


def _min_major(spec: str) -> int | None:
    """Return the smallest acceptable major across all ``||`` alternatives.

    ``||`` is an OR union: the plugin runs if ANY alternative is satisfied.
    So if even one alternative sets no lower floor (a wildcard like ``*``,
    or an upper-bound-only comparator like ``<21``), the union as a whole
    accepts every version — there is NO effective minimum and we must
    return None (the caller then never warns). We therefore short-circuit
    to None on the first no-floor alternative rather than skipping it and
    reducing over the bounded ones (which would over-warn: e.g. ``* ||
    >=20`` must NOT warn on a Node 12 host).
    """
    result: int | None = None
    for alt in spec.split("||"):
        floor = _alternative_floor(alt)
        if floor is None:
            # An unbounded alternative makes the whole OR union unbounded.
            return None
        if result is None or floor < result:
            result = floor
    return result


def main() -> int:
    if len(sys.argv) != 2:
        return 1
    path = Path(sys.argv[1])
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 1
    if not isinstance(payload, dict):
        return 1
    engines = payload.get("engines")
    if not isinstance(engines, dict):
        return 1
    node_spec = engines.get("node")
    if not isinstance(node_spec, str) or not node_spec.strip():
        return 1
    major = _min_major(node_spec)
    if major is None:
        return 1
    print(major)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
