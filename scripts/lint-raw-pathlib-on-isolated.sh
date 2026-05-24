#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/lint-raw-pathlib-on-isolated.sh — ratchet lint preventing NEW raw
# pathlib metadata probes AND raw pathlib mutators in `bridge-setup.py` +
# `bridge-hooks.py` that could land on paths under a v2-isolated agent's
# tree.
#
# Caught patterns:
#   - probes : `.exists()`, `.is_file()`, `.is_dir()`, `.is_symlink()`,
#              `.stat()`
#   - mutators (#1178 Deliverable Lint): `.mkdir(`, `.unlink(`, `.touch(`,
#              `.rmdir(`, `shutil.copy(`, `shutil.copy2(`, `shutil.move(`,
#              `shutil.rmtree(`, `os.makedirs(`, `os.remove(`, `os.rename(`
#
# Context: cycles 9-10-11 (#1165 → #1170 → #1175) all surfaced the same
# class of bug — a raw pathlib metadata probe inside the controller-side
# setup/render flow hit an isolated path the controller could not stat,
# raised PermissionError, and crashed the operator-facing recovery /
# rerender flow before the sudo-escalating fallback could fire. Per-cycle
# whack-a-mole fixed one site at a time; #1175 consolidated the canonical
# safe-helper into `lib/bridge_iso_paths.py` and swept the HIGH sites in
# both files. This lint is the regression guard: every NEW raw pathlib
# metadata call on an isolated path must either route through the safe
# wrapper (`_safe_path_check` / `_safe_read_env` / `_safe_load_json` from
# the shared module) OR carry an explicit `# noqa: raw-pathlib-controller-only`
# whitelist marker.
#
# Cycle 12 (#1178) extended the pattern to mutators after a setup teams
# rerun hit a raw `path.mkdir(parents=True, exist_ok=True)` in the
# `owner is None` branch of `_isolation_aware_mkdir` (the helper
# returned None because PermissionError was incorrectly swallowed as
# "no isolated lineage" — fixed in the same PR by routing through the
# new `_sudo_stat_owner` recovery). The lint extension catches the
# same class of bugs forward.
#
# ## Why two surfaces and not one
#
# `bridge-setup.py` handles `agent-bridge setup teams|telegram|discord`
# recovery and runs against `.teams/.env`, `.telegram/.env`, `.discord/.env`,
# `.mattermost/.env`, `.mcp.json`, `access.json` — all of which can be
# owned by an isolated `agent-bridge-<slug>` UID with the controller NOT
# in the per-agent supplementary group (#1170 family).
#
# `bridge-hooks.py` runs the hook layer that fires on every Claude
# session start. It inspects the isolated home's `.claude/settings.json`,
# the agent's workdir, the agent's skills dir, and the agent home tree
# — every entry-point can land on a v2-isolated subtree. PostToolUseFailure
# traceback flood (#1165 Gap 7) was driven by raw `Path.exists()` /
# `is_dir()` here.
#
# ## What counts as a "raw site"
#
# Any non-comment line in `bridge-setup.py` or `bridge-hooks.py` matching:
#   `<expr>.exists()` | `<expr>.is_file()` | `<expr>.is_dir()`
#   | `<expr>.is_symlink()` | `<expr>.stat()`
# where `<expr>` is anything that looks like a `Path`-typed variable.
#
# ## Whitelist
#
# - Lines containing `# noqa: raw-pathlib-controller-only` are skipped.
#   These mark deliberate controller-only call sites (operator-supplied
#   token-file paths, controller-owned channels-home dotenv, primitives
#   used by both controller and iso-routed callers, etc.) and the
#   import-time lib-dir probe.
# - Lines whose first non-whitespace char is `#` are skipped (comments).
# - Lines inside triple-quoted strings (docstring text) are skipped via
#   a heuristic: if the matched expression is preceded by a backtick or
#   surrounded by backticks on the line, treat as documentation. This is
#   imperfect but cheap.
#
# ## Sister lint
#
# Analog to `scripts/lint-heredoc-ban.sh` (footgun #11). Same baseline-by-
# count ratchet shape; new sites must explicitly noqa or refactor.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

BASELINE_FILE="${BRIDGE_RAW_PATHLIB_BASELINE_FILE:-$REPO_ROOT/scripts/baselines/raw-pathlib-baseline.txt}"

declare -a TARGETS=(
  "bridge-setup.py"
  "bridge-hooks.py"
)

# Pattern: match probe + mutator surfaces.
#
# Probes (zero-arg): `.exists()`, `.is_file()`, `.is_dir()`,
# `.is_symlink()`, `.stat()` — these always carry empty parens.
#
# Mutators: open-paren only (the calls may carry kwargs like
# `parents=True, exist_ok=True` for `.mkdir`, or `missing_ok=True` for
# `.unlink`, or positional args for `shutil.copy*` / `os.rename`). Match
# the start of the call shape (`.mkdir(`, etc.) and let argument
# matching extend naturally to the line's content; argv content does
# not need to be re-validated by the pattern.
#
# `shutil.copy(` is matched separately so it does not also match
# `shutil.copy2(` (the open-paren anchor would otherwise double-count).
# Same for `os.remove(` vs `os.rename(`.
#
# The pattern is anchored to a non-identifier character so a function
# definition like `def mkdir_unrelated(` does not trip the lint
# (`def mkdir_unrelated(` does not contain `.mkdir(`).
danger_pattern='\.(exists|is_file|is_dir|is_symlink|stat)\(\)|\.(mkdir|unlink|touch|rmdir)\(|shutil\.(copy|copy2|move|rmtree)\(|os\.(makedirs|remove|rename)\('

# Whitelist marker: a line with `# noqa: raw-pathlib-controller-only`
# anywhere in it is skipped (deliberate controller-only call site).
whitelist_marker='# noqa: raw-pathlib-controller-only'

# Comment-only line filter. The input shape is grep -n output:
# "LINENO:CONTENT" — so the prefix is `<digits>:` followed by optional
# whitespace then `#`. Matching just `^[[:space:]]*#` would never fire
# against the grep output stream.
comment_prefix='^[0-9]+:[[:space:]]*#'

list_sites() {
  local file="$1"
  # 1st pass: every line containing the danger pattern with line numbers.
  # 2nd pass: drop lines marked with the whitelist noqa.
  # 3rd pass: drop comment-only lines.
  # 4th pass: drop lines that look like docstring matches (the
  # `<expr>.exists()` appears inside backticks, i.e. ``path.exists()``).
  # The heuristic is: if the line, AFTER removing leading whitespace,
  # starts with `#`, OR if the danger pattern is wrapped in backticks
  # (``...``), it's docstring/comment text.
  grep -nE "$danger_pattern" "$file" 2>/dev/null \
    | grep -vF "$whitelist_marker" \
    | grep -vE "$comment_prefix" \
    | awk -F: '
      {
        line = $0
        # Reassemble the content portion (everything after the first colon).
        idx = index(line, ":")
        rest = substr(line, idx + 1)
        idx2 = index(rest, ":")
        content = substr(rest, idx2 + 1)
        # If the danger pattern is wrapped in backticks on this line, treat as docstring.
        # Simple heuristic: presence of "`...exists()`" / "`...is_dir()`" / "`...mkdir(`" etc.
        if (content ~ /`[^`]*\.(exists|is_file|is_dir|is_symlink|stat)\(\)/) next
        if (content ~ /`[^`]*\.(mkdir|unlink|touch|rmdir)\(/) next
        if (content ~ /`[^`]*shutil\.(copy|copy2|move|rmtree)\(/) next
        if (content ~ /`[^`]*os\.(makedirs|remove|rename)\(/) next
        # Also skip lines that are clearly inside docstring blocks
        # (lines starting with quote characters of triple-quote, or
        # entirely-text continuation lines that contain no `(` other
        # than the matched pattern). The simplest filter: skip lines
        # whose content (after leading whitespace) starts with `#` —
        # but those were already dropped above. Skip lines that are
        # entirely inside a comment block via `:    """`-prefixed
        # check.
        # Skip lines that look like Sphinx-style docstring text
        # (start with a lowercase word + `_` like `_safe_path_check`).
        # That heuristic is too noisy though; rely on backtick filter.
        print line
      }
    ' || true
}

count_sites() {
  local file="$1"
  list_sites "$file" | wc -l | awk '{print $1}'
}

run_check() {
  local mode="${1:-check}"
  local overall_rc=0
  local target_file
  local count

  if [[ ! -f "$BASELINE_FILE" ]]; then
    echo "[lint-raw-pathlib-on-isolated] FAIL: baseline file missing: $BASELINE_FILE" >&2
    echo "[lint-raw-pathlib-on-isolated] Run: $0 --baseline-update" >&2
    return 2
  fi

  for rel_path in "${TARGETS[@]}"; do
    target_file="$REPO_ROOT/$rel_path"
    if [[ ! -f "$target_file" ]]; then
      echo "[lint-raw-pathlib-on-isolated] target file missing: $target_file" >&2
      overall_rc=2
      continue
    fi

    count="$(count_sites "$target_file")"
    # Resolve the ceiling for this file from the baseline.
    local ceiling
    ceiling="$(grep -E "^${rel_path}:" "$BASELINE_FILE" 2>/dev/null | head -1 | awk -F: '{print $2}')"
    if [[ -z "$ceiling" ]]; then
      echo "[lint-raw-pathlib-on-isolated] FAIL: no baseline entry for $rel_path in $BASELINE_FILE" >&2
      overall_rc=2
      continue
    fi

    if [[ "$mode" == "list" ]]; then
      echo "== $rel_path (count: $count, ceiling: $ceiling) =="
      list_sites "$target_file"
      echo
      continue
    fi

    if [[ "$count" -gt "$ceiling" ]]; then
      echo "[lint-raw-pathlib-on-isolated] FAIL: $rel_path has $count raw pathlib metadata sites, exceeding the baseline ceiling ($ceiling)." >&2
      echo "[lint-raw-pathlib-on-isolated] New sites must either route through the canonical safe wrapper" >&2
      echo "[lint-raw-pathlib-on-isolated] (\`_safe_path_check\` / \`_safe_read_env\` / \`_safe_load_json\` in lib/bridge_iso_paths.py)" >&2
      echo "[lint-raw-pathlib-on-isolated] OR carry an explicit \`# noqa: raw-pathlib-controller-only\` whitelist marker." >&2
      echo "[lint-raw-pathlib-on-isolated]" >&2
      echo "[lint-raw-pathlib-on-isolated] Detected sites in $rel_path:" >&2
      list_sites "$target_file" | sed 's/^/[lint-raw-pathlib-on-isolated]   /' >&2
      overall_rc=1
      continue
    fi

    if [[ "$count" -lt "$ceiling" ]]; then
      echo "[lint-raw-pathlib-on-isolated] note: $rel_path count=$count is below ceiling=$ceiling. Lower the baseline entry to ratchet."
    fi

    echo "[lint-raw-pathlib-on-isolated] PASS: $rel_path count=$count, ceiling=$ceiling"
  done

  return "$overall_rc"
}

run_baseline_update() {
  : >"$BASELINE_FILE.tmp"
  local rel_path target_file count
  for rel_path in "${TARGETS[@]}"; do
    target_file="$REPO_ROOT/$rel_path"
    if [[ ! -f "$target_file" ]]; then
      echo "[lint-raw-pathlib-on-isolated] target file missing: $target_file" >&2
      rm -f "$BASELINE_FILE.tmp"
      return 2
    fi
    count="$(count_sites "$target_file")"
    printf '%s:%s\n' "$rel_path" "$count" >>"$BASELINE_FILE.tmp"
  done
  mv "$BASELINE_FILE.tmp" "$BASELINE_FILE"
  echo "[lint-raw-pathlib-on-isolated] baseline updated: $BASELINE_FILE"
  cat "$BASELINE_FILE"
}

run_self_test() {
  local fixture
  fixture="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$fixture'" RETURN

  # Build fixture with positives across probe + mutator surfaces +
  # whitelisted + comment + docstring backtick samples.
  cat >"$fixture" <<'PYEOF'
# Comment line mentioning path.exists() — should NOT match.
    """Docstring mentioning `path.exists()` — should NOT match either."""
    """Docstring mentioning `path.mkdir(parents=True)` — should NOT match."""
    """Docstring mentioning `shutil.copy2(a, b)` — should NOT match."""
def foo():
    return path.exists()
def bar():
    return path.is_dir()  # noqa: raw-pathlib-controller-only — whitelisted
def baz():
    if entry.is_file():
        return True
def quux():
    path.mkdir(parents=True, exist_ok=True)
def qux():
    target.unlink()  # noqa: raw-pathlib-controller-only — whitelisted
def freem():
    shutil.copy2(src, dst)
def garply():
    os.makedirs(path)
PYEOF

  # Expected positives:
  #   path.exists()    — line 6
  #   entry.is_file()  — line 10
  #   path.mkdir(...)  — line 13 (NEW #1178)
  #   shutil.copy2     — line 17 (NEW #1178)
  #   os.makedirs      — line 19 (NEW #1178)
  # Filtered out: comment line, 3 docstring lines (backtick-wrapped),
  # 2 whitelist-marked lines.
  local got expected
  got="$(count_sites "$fixture")"
  expected=5
  if [[ "$got" != "$expected" ]]; then
    echo "[lint-raw-pathlib-on-isolated] SELF-TEST FAIL: expected $expected, got $got" >&2
    echo "[lint-raw-pathlib-on-isolated] matches:" >&2
    list_sites "$fixture" | sed 's/^/[lint-raw-pathlib-on-isolated]   /' >&2
    return 1
  fi
  echo "[lint-raw-pathlib-on-isolated] SELF-TEST PASS: $got positives (whitelist + comment + docstring filtered)."
  return 0
}

case "${1:-}" in
  --list)
    run_check list
    exit $?
    ;;
  --baseline-update)
    run_baseline_update
    exit $?
    ;;
  --self-test)
    run_self_test
    exit $?
    ;;
  ""|--check)
    run_check check
    exit $?
    ;;
  *)
    echo "Usage: $0 [--check | --list | --baseline-update | --self-test]" >&2
    exit 2
    ;;
esac
