#!/usr/bin/env bash
# scripts/iso-helper-ratchet.sh — controller-to-isolated boundary ratchet.
#
# Per beta23 codex r1 spec, scan tracked source for raw mentions of the
# isolated artifact filename families and report any unallowlisted hits.
# This is the regression gate that future PRs must not exceed.
#
# Pattern (codex r1 spec verbatim):
#
#   rg --no-heading --line-number \
#     -e '\.env|\.access\.json|installed_plugins\.json|known_marketplaces\.json|webhook-port|settings\.effective\.json|agent-env\.sh' \
#     -- *.sh *.py lib/*.sh lib/*.py
#
# Allowlist:
#   - Lines containing a noqa marker (`# noqa: iso-helper-boundary`).
#   - Files explicitly listed in scripts/baselines/iso-helper-allowlist.txt
#     (whole-file allowlist for compatibility wrappers and helper internals).
#   - bridge_iso_run helper internals (lib/bridge-isolation-helpers.sh,
#     lib/bridge_iso_paths.py).
#   - The smoke + ratchet scripts themselves.
#   - The lint baseline files (they only contain counts, not raw boundary
#     callsites).
#
# Sister lint to scripts/lint-raw-pathlib-on-isolated.sh and
# scripts/lint-heredoc-ban.sh. Same baseline-by-count ratchet shape: a
# `scripts/baselines/iso-helper-baseline.txt` file records the
# per-file count snapshot at PR landing. The lint passes when current
# count <= baseline (regression-only, no greenfield enforcement).
#
# Exits:
#   0 — no regression beyond baseline
#   1 — regression: new boundary site introduced
#   2 — internal error (missing rg, baseline corrupt, etc.)
#
# Usage:
#   ./scripts/iso-helper-ratchet.sh                  # check
#   ./scripts/iso-helper-ratchet.sh --update-baseline  # regenerate baseline
#                                                       (use when migrating
#                                                       sites to the helper)
#
# Footgun #11: this script must not use heredoc-stdin or here-string
# anywhere in its body. All file iteration goes through `while read` from
# a regular file (mktemp-staged), never `done < <(...)` process-sub.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

BASELINE_FILE="${BRIDGE_ISO_HELPER_BASELINE_FILE:-$REPO_ROOT/scripts/baselines/iso-helper-baseline.txt}"
ALLOWLIST_FILE="${BRIDGE_ISO_HELPER_ALLOWLIST_FILE:-$REPO_ROOT/scripts/baselines/iso-helper-allowlist.txt}"

MODE="check"
case "${1:-}" in
  --update-baseline|--regenerate)
    MODE="regenerate"
    ;;
  --help|-h|help)
    cat <<'USAGE'
Usage: scripts/iso-helper-ratchet.sh [--update-baseline]

Scans tracked source for controller->isolated boundary callsites that
mention isolated artifact filenames. Enforces baseline-by-count: no
new sites may be introduced without explicitly migrating an existing
one OR adding the `# noqa: iso-helper-boundary` marker.

Options:
  --update-baseline   Regenerate scripts/baselines/iso-helper-baseline.txt
                      with the current counts. Use after intentionally
                      migrating sites.
  --help              This message.
USAGE
    exit 0
    ;;
esac

if ! command -v rg >/dev/null 2>&1; then
  echo "[iso-helper-ratchet] ripgrep (rg) not found; install via 'brew install ripgrep' or apt." >&2
  exit 2
fi

# Pattern set — boundary-anchored isolated-artifact filename families.
#
# Originally the codex r1 spec shipped the bare alternation
#   \.env|\.access\.json|...|agent-env\.sh
# but that substring-matches: `\.env` fires inside `os.environ` /
# `environ[` / `environment`, and `settings\.effective\.json` fires on
# fixture paths that merely mention the filename. Both are false
# positives (no controller->isolated boundary RW), and each cost a
# diagnose+noqa+push round (#1749/#1757/#1761, 2026-06-10).
#
# Fix: require a trailing word-boundary — each filename token must be
# followed by a NON-word character or end-of-line. `os.environ` no longer
# matches because the `.env` substring is followed by `i` (a word char);
# a real `/.env`, `".env"`, `.env.bak`, or `agent-env.sh "` reference
# still matches because it is followed by `/`, quote, `.`, space, etc.
#
# Portability: ripgrep's default (Rust) regex engine runs identically on
# Linux CI and macOS dev hosts, so no BSD-vs-GNU grep skew applies here.
# The trailing guard uses a POSIX-safe negated character class
# `[^A-Za-z0-9_]` (no GNU-only `\b`) and `$`; rg lacks look-around so the
# negated-class form is the portable equivalent of a `(?![A-Za-z0-9_])`
# negative lookahead.
PATTERN='(\.env|\.access\.json|installed_plugins\.json|known_marketplaces\.json|webhook-port|settings\.effective\.json|agent-env\.sh)([^A-Za-z0-9_]|$)'

# Noqa marker callers can use to explicitly mark a controller-only site.
NOQA_MARKER='# noqa: iso-helper-boundary'

# Build the file allowlist set. Files explicitly listed in
# scripts/baselines/iso-helper-allowlist.txt are skipped entirely
# (whole-file allowlist). Always-allowlisted files:
#   - This ratchet script
#   - The helper unit smoke + the anchoring self-test smoke (both
#     deliberately contain boundary-shaped fixture strings)
#   - The baseline + allowlist files themselves
#   - bridge_iso_run helper internals
declare -A ALLOWED_FILES=(
  ["scripts/iso-helper-ratchet.sh"]=1
  ["scripts/iso-helper-smoke.sh"]=1
  ["scripts/smoke/1764-ratchet-anchoring.sh"]=1
  ["lib/bridge-isolation-helpers.sh"]=1
  ["lib/bridge_iso_paths.py"]=1
)

if [[ -f "$ALLOWLIST_FILE" ]]; then
  while IFS= read -r _line; do
    [[ -n "$_line" && "${_line:0:1}" != "#" ]] || continue
    ALLOWED_FILES["$_line"]=1
  done <"$ALLOWLIST_FILE"
fi

# File set: every tracked *.sh + *.py at repo root and under lib/.
# Use git ls-files when available to skip uncommitted scratch.
TARGETS_TMP="$(mktemp "${TMPDIR:-/tmp}/agb-iso-ratchet-tgts.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$TARGETS_TMP' 2>/dev/null" EXIT INT TERM

if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$REPO_ROOT" ls-files '*.sh' '*.py' 'lib/*.sh' 'lib/*.py' 2>/dev/null \
    | sort -u >"$TARGETS_TMP"
else
  ( cd "$REPO_ROOT" \
      && ls -1 ./*.sh ./*.py lib/*.sh lib/*.py 2>/dev/null ) \
    | sed 's,^\./,,' \
    | sort -u >"$TARGETS_TMP"
fi

# count_file <relpath> -> int
# Counts boundary lines in <relpath> (relative to REPO_ROOT). Excludes
# lines bearing the noqa marker. Excludes comment-only lines (the
# baseline tracks lines that COULD become a runtime call, not
# documentation lines that mention the pattern in passing). When the
# file is whole-file allowlisted, returns 0 unconditionally.
count_file() {
  local relpath="$1"
  if [[ -n "${ALLOWED_FILES[$relpath]:-}" ]]; then
    printf 0
    return 0
  fi
  local absolute="$REPO_ROOT/$relpath"
  [[ -f "$absolute" ]] || { printf 0; return 0; }
  # rg --no-heading --line-number with the pattern set.
  # Pipe to grep -v for noqa filter; then drop comment-only lines via awk.
  local n
  n="$(rg --no-heading --line-number -e "$PATTERN" "$absolute" 2>/dev/null \
        | grep -vF -- "$NOQA_MARKER" \
        | awk -F: '
            {
              # Reassemble content after "<lineno>:" prefix.
              idx = index($0, ":")
              rest = substr($0, idx + 1)
              # Skip lines whose content (after leading whitespace) starts with #.
              sub(/^[ \t]*/, "", rest)
              if (rest ~ /^#/) next
              print
            }
          ' \
        | wc -l)"
  printf '%s' "$(echo "$n" | tr -d ' ')"
}

# baseline_get <relpath> -> count (or 0 when unknown)
baseline_get() {
  local relpath="$1"
  local got
  got="$(grep -E "^${relpath}=" "$BASELINE_FILE" 2>/dev/null | head -1 | sed -E 's/^[^=]+=//')"
  if [[ -z "$got" ]]; then
    printf 0
  else
    printf '%s' "$got"
  fi
}

# ---- Regenerate mode -------------------------------------------------------

if [[ "$MODE" == "regenerate" ]]; then
  mkdir -p "$(dirname "$BASELINE_FILE")"
  REGEN_TMP="$(mktemp "${TMPDIR:-/tmp}/agb-iso-ratchet-regen.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$REGEN_TMP' '$TARGETS_TMP' 2>/dev/null" EXIT INT TERM
  {
    printf '# Auto-generated by scripts/iso-helper-ratchet.sh --update-baseline\n'
    printf '# Format: <relpath>=<count>\n'
    printf '# Edits to this file are tracked. Adding a new entry implicitly\n'
    printf '# grants the current count as the per-file ceiling.\n'
    printf '#\n'
    printf '# Baseline records the controller->isolated boundary footprint at\n'
    printf '# the moment of capture; the ratchet refuses new sites beyond this\n'
    printf '# count without an explicit baseline regeneration commit.\n'
    printf '\n'
    while IFS= read -r relpath; do
      [[ -n "$relpath" ]] || continue
      [[ -n "${ALLOWED_FILES[$relpath]:-}" ]] && continue
      local_count="$(count_file "$relpath")"
      [[ "$local_count" -gt 0 ]] || continue
      printf '%s=%s\n' "$relpath" "$local_count"
    done <"$TARGETS_TMP"
  } >"$REGEN_TMP"
  mv -f "$REGEN_TMP" "$BASELINE_FILE"
  echo "[iso-helper-ratchet] baseline regenerated at $BASELINE_FILE"
  exit 0
fi

# ---- Check mode ------------------------------------------------------------

if [[ ! -f "$BASELINE_FILE" ]]; then
  echo "[iso-helper-ratchet] baseline file missing at $BASELINE_FILE" >&2
  echo "[iso-helper-ratchet] run '$0 --update-baseline' to generate." >&2
  exit 2
fi

REGRESSIONS=0
NEW_SITES=0
SUMMARY_TMP="$(mktemp "${TMPDIR:-/tmp}/agb-iso-ratchet-sum.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$SUMMARY_TMP' '$TARGETS_TMP' 2>/dev/null" EXIT INT TERM

while IFS= read -r relpath; do
  [[ -n "$relpath" ]] || continue
  [[ -n "${ALLOWED_FILES[$relpath]:-}" ]] && continue
  current="$(count_file "$relpath")"
  baseline="$(baseline_get "$relpath")"
  if [[ "$current" -gt "$baseline" ]]; then
    delta=$((current - baseline))
    REGRESSIONS=$((REGRESSIONS + delta))
    NEW_SITES=$((NEW_SITES + 1))
    printf 'REGRESSION %s baseline=%d current=%d delta=+%d\n' \
      "$relpath" "$baseline" "$current" "$delta" >>"$SUMMARY_TMP"
  fi
done <"$TARGETS_TMP"

if [[ "$REGRESSIONS" -gt 0 ]]; then
  echo "[iso-helper-ratchet] REGRESSION: $REGRESSIONS new boundary site(s) across $NEW_SITES file(s)" >&2
  cat "$SUMMARY_TMP" >&2
  echo "" >&2
  echo "Action: route new callsites through bridge_iso_run (shell) or" >&2
  echo "        bridge_iso_paths.iso_run (Python), OR add" >&2
  echo "        '$NOQA_MARKER' on the line if it is a deliberate" >&2
  echo "        controller-only callsite (operator-supplied token files," >&2
  echo "        controller-owned channels-home dotenv, etc.)." >&2
  echo "" >&2
  echo "        After intentional migration, run:" >&2
  echo "          $0 --update-baseline" >&2
  echo "        and commit the updated baseline." >&2
  exit 1
fi

echo "[iso-helper-ratchet] OK (no regression beyond baseline)"
exit 0
