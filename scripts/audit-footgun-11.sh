#!/usr/bin/env bash
# scripts/audit-footgun-11.sh — enumerate every heredoc-stdin subprocess site
# in tracked shell sources and classify them per the footgun #11 taxonomy.
#
# Context: footgun #11 is the Bash 5.3.9 `read_comsub` / `heredoc_write`
# deadlock chain. The same syntactic shape — feeding a subprocess's stdin
# from a heredoc while a parent waits on its stdout — has caused outages
# in v0.13.7, v0.13.8, v0.13.9, PR #940, PR #943, and queue task #4807.
# This audit produces the ground truth that Phase 2-6 extractions ratchet
# against, and that scripts/lint-heredoc-ban.sh consumes for the CI guard.
#
# Taxonomy (mirror of the Phase 1 plan in task #4810/#4811):
#   C1  heredoc inside ANY capture wrapper — `$(...)`, backticks, env-prefix
#       inside capture, pipes feeding capture. Zero new tolerance.
#   C2  `cat <<EOF` inside `$(...)`. Sub-category of C1 kept as a distinct
#       label because the wedge profile is different (cat reaper vs slow
#       interpreter consumer).
#   C3  heredoc-fed interpreter (`python3 - <<PY`, `bash -s -- <<EOF`,
#       `perl -<<PL`, `ruby - <<RB`, `awk -f /dev/stdin <<AWK`,
#       `node - <<JS`) OUTSIDE any capture wrapper. The historical
#       "off-leap" upgrader carry-over lives here. Migration is desirable
#       but not block-on-new.
#   C4  `bash -s [...] <<EOF` outside capture. Sub-category of C3; kept
#       distinct because it is the deadlock variant the upgrader actually
#       tripped on in v0.13.7-9.
#   H3  here-string (`<<<`), process substitution input (`< <(...)`),
#       `source /dev/stdin <<<...`. Classified per-site: producer/
#       consumer/hot-path/cold-path noted in `reason`.
#   SAFE write-to-file (`cat > path <<EOF`), usage/help text printed to
#       stdout/stderr (`cat <<EOF` at top level, not in capture, not
#       sourced), and self-test fixtures. Documented so reviewers can
#       distinguish "we left it on purpose" from "we missed it".
#
# Output modes:
#   --tsv         (default) tab-separated rows:
#                 path<TAB>line<TAB>category<TAB>snippet_hash<TAB>reason<TAB>snippet
#   --json        one JSON object per line (jsonlines)
#   --summary     count per category, single-line totals at the end
#
# Usage:
#   scripts/audit-footgun-11.sh                    # tsv to stdout
#   scripts/audit-footgun-11.sh --json             # jsonlines to stdout
#   scripts/audit-footgun-11.sh --summary          # per-category counts
#   scripts/audit-footgun-11.sh --tsv > out.tsv    # capture for baseline
#
# Determinism:
#   - File list comes from `git ls-files`, sorted.
#   - Sites within a file are emitted in line-number order.
#   - snippet_hash is SHA-256 of a whitespace-normalized snippet so the
#     identity anchor survives reformatting and line drift.
#
# This script is intentionally read-only. It never mutates the tree.

set -euo pipefail

# This script uses associative arrays (`declare -A`), which require Bash 4+.
# On macOS, /usr/bin/env bash typically resolves to /bin/bash 3.2 (Apple's
# stock build), which aborts the declare-A line with "unbound variable" and
# leaves the lint shipping in `lint-heredoc-ban.sh --baseline-check` with a
# non-actionable failure (r2 fix for codex PR #954 r1 finding P2 #1). Re-exec
# via the first Bash 4+ interpreter we can find so the script works on
# developer macOS machines, not just Linux CI.
if (( BASH_VERSINFO[0] < 4 )); then
  _audit_bash4=""
  if [[ -n "${BASH4_BIN:-}" && -x "${BASH4_BIN}" ]]; then
    _audit_bash4="$BASH4_BIN"
  else
    for _cand in \
      "$(command -v bash4 2>/dev/null || true)" \
      /opt/homebrew/bin/bash \
      /usr/local/bin/bash \
    ; do
      if [[ -n "$_cand" && -x "$_cand" ]]; then
        _audit_bash4="$_cand"
        break
      fi
    done
  fi
  if [[ -z "$_audit_bash4" ]]; then
    echo "audit-footgun-11: requires Bash 4+ (declare -A); found Bash ${BASH_VERSION}." >&2
    echo "audit-footgun-11: install Homebrew bash (\`brew install bash\`) or set BASH4_BIN to a Bash 4+ interpreter." >&2
    exit 2
  fi
  exec "$_audit_bash4" "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mode="tsv"
case "${1:-}" in
  --tsv|"")  mode="tsv" ;;
  --json)    mode="json" ;;
  --summary) mode="summary" ;;
  -h|--help)
    sed -n '2,52p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "audit-footgun-11: unknown arg: ${1}" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Source file enumeration. Same surface the existing CI lints scan, plus
# the modular smokes under scripts/smoke/.
# ---------------------------------------------------------------------------
collect_sources() {
  (
    cd "$repo_root"
    git ls-files \
      '*.sh' \
      'agent-bridge' \
      'agb' \
      'lib/*.sh' \
      'scripts/*.sh' \
      'scripts/smoke/*.sh' \
      'agent-roster.local.example.sh' \
      2>/dev/null \
    | sort -u
  )
}

# ---------------------------------------------------------------------------
# sha256 of stdin (portable shasum vs sha256sum).
# ---------------------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  _sha256() { sha256sum | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  _sha256() { shasum -a 256 | awk '{print $1}'; }
else
  echo "audit-footgun-11: need sha256sum or shasum" >&2
  exit 2
fi

# Normalize a snippet: strip leading/trailing whitespace, collapse internal
# runs of whitespace to single space, drop trailing comments after #. The
# hash is identity, not content — robust against indentation reformatting.
normalize_snippet() {
  local s="$1"
  # Strip trailing inline comment (# preceded by space).
  s="${s%%[[:space:]]#*}"
  # Collapse whitespace runs.
  s="$(printf '%s' "$s" | tr -s '[:space:]' ' ')"
  # Trim leading and trailing whitespace.
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# JSON-escape a string. We avoid `python3 -c ... <<<` here because the
# whole point of this audit is to expose footgun #11 patterns and we
# should not be a producer of new ones. Instead we use a small awk
# implementation that handles the JSON-required escapes.
json_escape() {
  local s="$1"
  printf '%s' "$s" | awk '
  BEGIN {
    for (i = 0; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
    printf "\""
  }
  {
    if (NR > 1) printf "\\n"
    line = $0
    out = ""
    n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (c == "\\") { out = out "\\\\"; continue }
      if (c == "\"") { out = out "\\\""; continue }
      if (c == "/")  { out = out "/";    continue }
      if (c in ctl)  { out = out ctl[c]; continue }
      out = out c
    }
    printf "%s", out
  }
  END { printf "\"" }
  '
}

# ---------------------------------------------------------------------------
# Classification.
#
# We decide a line's category by combining:
#   (1) whether it contains a heredoc operator (`<<`, `<<-`, `<<<`)
#   (2) what the command before that operator is
#   (3) whether the line opens a capture wrapper (`$(`, backtick)
#   (4) whether it's a write-to-file heredoc (`cmd > path <<...`)
# ---------------------------------------------------------------------------

# Patterns. POSIX ERE; tested in scripts/smoke/lint-heredoc-scanner-self.sh.
#
# RE_HEREDOC_OP tolerates whitespace between `<<` / `<<-` and the delimiter
# ONLY when the delimiter is quoted (`<<  'PY'`, `<<  "PY"`). Bash accepts
# both quoted and unquoted-with-whitespace, but unquoted `<<  TOKEN` is
# indistinguishable from a comparison expression `"x << y"` inside a string
# (e.g. `"elapsed << interval"`) and produces a false positive that
# trips the lint on prose. Quoted-only is sufficient to catch the actual
# r3 P2 #2 case (the only whitespace-tolerant shape that has shown up in
# the tree). r3 fix for codex PR #954 r2 finding P2 #2 — combined with the
# tightening above to avoid prose-text false positives.
RE_HEREDOC_OP='<<-?([[:space:]]*["'"'"'][A-Za-z_][A-Za-z0-9_]*["'"'"']|["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?)'
RE_HERESTRING='<<<'
RE_PROCSUB_IN='<[[:space:]]+<\('
RE_PROCSUB_OUT='>[[:space:]]+>\('
# Interpreter consumers the deadlock pattern actually hits.
# Bash regex is ERE — `\b` is not supported. Use explicit boundary
# character classes so we don't fire on `bashrc` / `python3.11-config`.
RE_INTERP='(^|[^A-Za-z0-9_/.-])(bash|sh|zsh|python3?|perl|ruby|node|awk)[[:space:]]+(-s|-|-f[[:space:]]+/dev/stdin)([[:space:]]|$)'
RE_CAT_HEREDOC='(^|[^A-Za-z0-9_])cat[[:space:]]*(>[^|<>]*|>>[^|<>]*)?[[:space:]]*<<-?'
RE_REDIR_OUT='>[[:space:]]*"?[^|<>[:space:]]+"?[[:space:]]*<<-?'
RE_BASH_S='(^|[^A-Za-z0-9_/.-])bash[[:space:]]+-s([[:space:]]|$)'
# r2 (codex integration review #5818): bare `bash <<TAG` is the same
# heredoc-stdin-to-bash-subprocess shape as `bash -s <<TAG`. Earlier
# the scanner only matched `-s`; this catches the bare form so
# slipped-through smokes get flagged.
RE_BASH_BARE_HEREDOC='(^|[^A-Za-z0-9_/.-])bash[[:space:]]+<<-?'

# Is the heredoc operator on this line preceded by `$(` or backtick on
# the SAME line — i.e. it opens a capture-wrapped heredoc? Cross-line
# captures (where the capture opens on a prior line and the heredoc sits
# on a continuation) are out of scope for the per-line classifier and
# get caught by reviewers via the audit listing.
in_capture_line() {
  local line="$1"
  local trimmed="${line#"${line%%[![:space:]]*}"}"
  if [[ "$trimmed" == \#* ]]; then
    return 1
  fi
  if [[ "$line" == *'$('* ]]; then
    local before_op="${line%%<<*}"
    if [[ "$before_op" == *'$('* ]]; then
      return 0
    fi
  fi
  if [[ "$line" == *'`'* ]]; then
    local before_op="${line%%<<*}"
    if [[ "$before_op" == *'`'* ]]; then
      return 0
    fi
  fi
  return 1
}

# Pure write-to-file heredoc (`cmd > path <<EOF`) outside capture.
is_output_file_heredoc() {
  local line="$1"
  if [[ "$line" =~ $RE_REDIR_OUT ]]; then
    if in_capture_line "$line"; then
      return 1
    fi
    return 0
  fi
  return 1
}

# Heredoc OR here-string OR process-sub presence.
line_has_heredoc_like() {
  local line="$1"
  if [[ "$line" =~ $RE_HEREDOC_OP ]]; then return 0; fi
  if [[ "$line" =~ $RE_HERESTRING ]]; then return 0; fi
  if [[ "$line" =~ $RE_PROCSUB_IN ]]; then return 0; fi
  if [[ "$line" =~ $RE_PROCSUB_OUT ]]; then return 0; fi
  return 1
}

# Classify one line. Echoes `CATEGORY|REASON`.
# CATEGORY ∈ {C1, C2, C3, C4, H3, SAFE, NONE}.
#
# $1: raw line.
# $2: entry capture state — non-zero if a `$(...)` or backtick from a
#     PRIOR line is still open at the moment this line is read. Set by
#     scan_file() via the cross-line capture tracker (r3 fix for codex
#     PR #954 r2 finding P1). When non-zero, any heredoc-op on this line
#     is inside a capture wrapper regardless of single-line shape, so we
#     classify as C1 (cat-in-capture stays C2 because the sub-class is
#     meaningful for the deadlock profile).
classify_line() {
  local line="$1"
  local entry_capture="${2:-0}"
  local trimmed="${line#"${line%%[![:space:]]*}"}"

  if [[ "$trimmed" == \#* ]]; then
    printf 'NONE|comment\n'
    return
  fi
  if [[ -z "$trimmed" ]]; then
    printf 'NONE|empty\n'
    return
  fi

  local has_heredoc_op=0 has_herestring=0 has_procsub=0
  [[ "$line" =~ $RE_HEREDOC_OP ]] && has_heredoc_op=1
  [[ "$line" =~ $RE_HERESTRING  ]] && has_herestring=1
  if [[ "$line" =~ $RE_PROCSUB_IN ]] || [[ "$line" =~ $RE_PROCSUB_OUT ]]; then
    has_procsub=1
  fi

  if (( has_heredoc_op == 0 && has_herestring == 0 && has_procsub == 0 )); then
    printf 'NONE|no-heredoc\n'
    return
  fi

  # Here-string / process-sub branch.
  if (( has_heredoc_op == 0 )) && (( has_herestring == 1 || has_procsub == 1 )); then
    if [[ "$line" =~ $RE_INTERP ]]; then
      printf 'H3|here-string/procsub feeding interpreter (review per-site)\n'
    else
      printf 'H3|here-string/procsub, non-interpreter consumer\n'
    fi
    return
  fi

  # Heredoc-op branch.
  # Cross-line check first: a write-to-file heredoc inside a capture isn't
  # safe (the redirect feeds a tempfile, but the OUTER capture still waits
  # on stdout); fold that into C1. Single-line is_output_file_heredoc already
  # disqualifies same-line capture via in_capture_line.
  if (( entry_capture == 0 )) && is_output_file_heredoc "$line"; then
    printf 'SAFE|write-to-file heredoc (cmd > path <<EOF)\n'
    return
  fi

  local in_cap=0
  if (( entry_capture > 0 )); then
    in_cap=1
  elif in_capture_line "$line"; then
    in_cap=1
  fi

  if (( in_cap == 1 )) && [[ "$line" =~ $RE_CAT_HEREDOC ]]; then
    printf 'C2|cat heredoc in capture\n'
    return
  fi
  if (( in_cap == 1 )); then
    local cross_line_note=""
    if (( entry_capture > 0 )); then
      cross_line_note=" (cross-line capture)"
    fi
    if [[ "$line" =~ $RE_INTERP ]]; then
      printf 'C1|interpreter heredoc in capture (deadlock class)%s\n' "$cross_line_note"
    else
      printf 'C1|heredoc in capture%s\n' "$cross_line_note"
    fi
    return
  fi

  # Outside capture.
  if [[ "$line" =~ $RE_BASH_S ]] && [[ "$line" =~ $RE_HEREDOC_OP ]]; then
    printf 'C4|bash -s heredoc, no capture\n'
    return
  fi
  # r2 (codex integration review #5818): bare `bash <<TAG` is same C4
  # bug class as `bash -s <<TAG` — heredoc-stdin to bash subprocess.
  if [[ "$line" =~ $RE_BASH_BARE_HEREDOC ]]; then
    printf 'C4|bare bash heredoc, no capture\n'
    return
  fi
  if [[ "$line" =~ $RE_INTERP ]]; then
    printf 'C3|interpreter heredoc, no capture\n'
    return
  fi

  printf 'SAFE|non-interpreter heredoc, no capture\n'
}

# ---------------------------------------------------------------------------
# Cross-line capture state tracking.
#
# `in_capture_line` only sees a single line, so a heredoc whose surrounding
# `$(...)` opened on a PRIOR line is mis-classified as C3 instead of C1.
# That made it possible to bypass the baseline ratchet by wrapping a
# baselined C3 site in multi-line capture (r3 fix for codex PR #954 r2
# finding P1). To close that gap, scan_file() walks every line of the file
# in order, maintaining `capture_depth` (the running count of unclosed
# `$(`) and `backtick_open` (parity of unescaped backticks). When a heredoc
# is opened, the body lines are skipped for paren counting until we see the
# delimiter line; otherwise we'd misread heredoc body content as code.
#
# The line stripper is deliberately conservative: it removes single-quoted
# strings (their contents are literal so `$(` inside them is not a capture)
# and inline comments. Double-quoted strings are KEPT because `"$(cmd)"` is
# a real capture wrapper and bash treats it as such. Edge cases like
# `\$(` (escaped) or `$(...)` split across lines via `\\` continuation are
# accepted as "best effort"; the false-positive cost of treating them as
# captures (C1 instead of C3) is strictly safer than the false-negative
# cost of letting a real capture-wrapped heredoc through as C3.
# ---------------------------------------------------------------------------

# Strip quoted segments and trailing comments from a line so we can
# safely count `$(` / `)` / backticks for cross-line capture tracking.
# Reads / writes the global vars `STRIP_IN_SINGLE` and `STRIP_IN_DOUBLE`
# so quote state PERSISTS across lines (a `'...'` argument can span many
# lines, e.g. `bash -c '\n  source ...\n  '`; without cross-line quote
# state the in-quote body lines would be mis-counted as code and pump
# capture_depth into the next chunk of file).
#
# Tracks BOTH single and double quote modes — important for the common
# bash escape `'"'"'` (close-quote, double-quote-literal-single, re-open
# quote). A single-mode-only stripper would mis-toggle on the middle `'`
# inside the double-quoted segment and emit phantom code, which would
# corrupt cross-line capture_depth. Inside double-quotes we KEEP `$(`,
# `)`, and backtick — they are real bash code (`"$(cmd)"` is a valid
# capture wrapper) — but we strip `'` literals so they don't enter
# single-mode.
#
# Writes its output to the global `STRIP_RESULT` instead of stdout so the
# caller doesn't have to `$()`-capture it — that would run this function
# in a subshell and lose the STRIP_IN_* updates the function makes.
STRIP_IN_SINGLE=0
STRIP_IN_DOUBLE=0
STRIP_RESULT=""
strip_quotes_and_comments() {
  local s="$1"
  local out=""
  local n=${#s}
  local i=0
  local ch
  # Running per-line `(` / `)` counts in `out`. Used by the `#` comment-
  # break check to detect "comment-marker appears inside an unclosed
  # `$(...)` open" — that's bash-illegal as a real comment, so the `#`
  # is actually inside a string the naive `"` toggle mis-tracked. Both
  # counts treat `$(` and bare `(` the same (any open keeps the line
  # tail).
  local strip_line_open_count=0 strip_line_close_count=0
  while (( i < n )); do
    ch="${s:i:1}"
    if (( STRIP_IN_SINGLE == 1 )); then
      if [[ "$ch" == "'" ]]; then
        STRIP_IN_SINGLE=0
      fi
      i=$((i + 1))
      continue
    fi
    if (( STRIP_IN_DOUBLE == 1 )); then
      # Backslash escapes the next char inside double-quotes too. Apply
      # the same `\$(` → swallow-paren rule as the outside-quote path
      # so a `printf "...\$(\n"` shape doesn't push a phantom `(` onto
      # the paren stack (r5 self-test).
      if [[ "$ch" == "\\" && $((i + 1)) -lt $n ]]; then
        local _esc_next="${s:i+1:1}"
        if [[ "$_esc_next" == '$' && $((i + 2)) -lt $n && "${s:i+2:1}" == '(' ]]; then
          i=$((i + 3))
        else
          i=$((i + 2))
        fi
        continue
      fi
      if [[ "$ch" == '"' ]]; then
        STRIP_IN_DOUBLE=0
        i=$((i + 1))
        continue
      fi
      # Inside double-quote, `$(`, `)`, and `` ` `` are still code.
      # Pass them through so capture counters see them.
      if [[ "$ch" == '(' ]]; then
        strip_line_open_count=$((strip_line_open_count + 1))
      elif [[ "$ch" == ')' ]]; then
        strip_line_close_count=$((strip_line_close_count + 1))
      fi
      out="${out}${ch}"
      i=$((i + 1))
      continue
    fi
    # Trailing comment: `#` preceded by whitespace or start of line.
    # Conservative rule: only strip `# ` (space-comment) or comment at
    # start of line so we don't trip on `${#var}`. Comment-only LINES
    # are already skipped by scan_file's `trimmed == #*` check before
    # this stripper is invoked.
    #
    # r5: also require that the stripper has emitted no unbalanced `(`
    # so far on this line. The naive `"` toggle can mis-read the entry
    # quote state when nested quotes appear inside
    # `"$(... "X" ... "Y" ...)"` (each inner `"..."` toggles dbl=1→0→1,
    # leaving us "outside" mid-string from the stripper's view even
    # though bash semantics keeps us inside the outer string). When a
    # `#` shows up inside such a string, breaking the loop would drop
    # the closing `)` of an open `$(`, leaking a phantom 'C' onto
    # CAPTURE_STACK and turning every downstream heredoc into a
    # cross-line C1/C2 false positive. The "any unbalanced `(` in
    # current `out`" check catches the common case where the `#` is
    # inside a string opened mid-line via `$( ... "..." # ... )"`.
    # Counts maintained inline so the comment-check is O(1) per line.
    if [[ "$ch" == "#" ]]; then
      if (( i == 0 )); then
        break
      fi
      local prev="${s:i-1:1}"
      if [[ "$prev" == " " || "$prev" == $'\t' ]]; then
        if (( strip_line_open_count <= strip_line_close_count )); then
          break
        fi
        # Unbalanced opens — keep going so the closing `)` is captured.
      fi
    fi
    if [[ "$ch" == "\\" && $((i + 1)) -lt $n ]]; then
      # Skip escaped char wholesale (e.g. \$, \`, \(, \) ). For `\$(`,
      # also swallow the trailing `(` — the escape turned `$(` into a
      # literal `$(` from bash's view (no command substitution opens),
      # so the `(` is structural NOPS and pushing it onto the paren
      # stack would unbalance everything downstream (r5 self-test
      # caught this on `printf "STATE_NEXT_TS=\$(\n"` shapes).
      local _esc_next="${s:i+1:1}"
      if [[ "$_esc_next" == '$' && $((i + 2)) -lt $n && "${s:i+2:1}" == '(' ]]; then
        i=$((i + 3))
      else
        i=$((i + 2))
      fi
      continue
    fi
    if [[ "$ch" == "'" ]]; then
      STRIP_IN_SINGLE=1
      i=$((i + 1))
      continue
    fi
    if [[ "$ch" == '"' ]]; then
      STRIP_IN_DOUBLE=1
      i=$((i + 1))
      continue
    fi
    if [[ "$ch" == '(' ]]; then
      strip_line_open_count=$((strip_line_open_count + 1))
    elif [[ "$ch" == ')' ]]; then
      strip_line_close_count=$((strip_line_close_count + 1))
    fi
    out="${out}${ch}"
    i=$((i + 1))
  done
  STRIP_RESULT="$out"
}

# Count occurrences of a literal substring in $1. Writes the count to
# the global `COUNT_RESULT`.
COUNT_RESULT=0
count_substr() {
  local hay="$1" needle="$2"
  local rest="$hay" hits=0
  while [[ "$rest" == *"$needle"* ]]; do
    hits=$((hits + 1))
    rest="${rest#*"$needle"}"
  done
  COUNT_RESULT=$hits
}

# Count unescaped backticks (each toggles backtick capture state). Writes
# the count to `COUNT_RESULT`.
count_backticks() {
  local s="$1"
  local n=${#s}
  local i=0 hits=0
  local ch
  while (( i < n )); do
    ch="${s:i:1}"
    if [[ "$ch" == "\\" && $((i + 1)) -lt $n ]]; then
      i=$((i + 2))
      continue
    fi
    if [[ "$ch" == '`' ]]; then
      hits=$((hits + 1))
    fi
    i=$((i + 1))
  done
  COUNT_RESULT=$hits
}

# Detect case-arm `pattern)` at line start and strip it before paren
# tracking. Bash case-arm patterns start at logical line beginning and
# end with `)` that has no matching `(`. Without stripping, the unmatched
# `)` would attempt to pop the top of the capture stack (a real prior
# `$(` capture) — codex PR #954 r3 P1 BLOCKING. The r5 paren-type-stack
# `)` handler treats empty-stack pops as silent (case-arm / parser-error
# tolerance), but stripping case arms BEFORE the stack walk preserves
# REAL captures across case branches instead of letting their tops get
# eaten.
#
# We tolerate the common pattern shapes: alphanumeric, `*`, `?`, `[...]`,
# `+`, `|`, `.`, with an optional alternation pipe. Patterns starting
# with `-` are deliberately NOT matched because that shape is far more
# often a continuation argument like `--json)` (multi-line `$(cmd
# --flag)"` close) than a case arm, and stripping the trailing `)` of
# a `--flag)` argument would unbalance the outer `$()` close count.
# Anything more exotic (e.g. patterns containing `(` or embedded `$()`)
# is rare and the counter degrades gracefully.
#
# Result goes to global `MAYBE_STRIP_RESULT` (not stdout) so callers can
# avoid `$()` subshell capture — that would lose the STRIP_CASE_ARM_FIRES
# debug counter increment and the side-effect would not survive (r5 P2
# verification hook).
MAYBE_STRIP_RESULT=""
STRIP_CASE_ARM_FIRES=0
maybe_strip_case_arm() {
  local s="$1"
  local trimmed leading
  trimmed="${s#"${s%%[![:space:]]*}"}"
  if [[ -z "$trimmed" ]]; then
    MAYBE_STRIP_RESULT="$s"
    return 0
  fi
  # Match: optional pattern alternation pipe(s), pattern chars, terminating
  # `)` followed by whitespace or end-of-line. Per `man bash` case-arm
  # pattern chars include `*`, `?`, `[...]`, `|`, and identifier chars.
  #
  # We disallow a LEADING `-` because that pattern shape is far more often
  # a continuation argument like `--json)` (command-line flag closer in a
  # multi-line `$(cmd --flag)"` expression) than a case-arm pattern.
  # Case-arm patterns don't conventionally start with `-` — bash supports
  # it syntactically but the convention is identifiers, globs, or literals.
  # Treating `--json)` as a case-arm would strip the `)` we need to keep
  # so the outer `$(...)` close count stays balanced.
  if [[ "$trimmed" =~ ^[A-Za-z0-9_*?\.+]([A-Za-z0-9_*?\.\|+\-]|\[[^\]]*\])*\)([[:space:]]|$) ]]; then
    leading="${BASH_REMATCH[0]}"
    # Strip everything up to and including the matched `pattern)`.
    s="${s/${leading}/}"
    STRIP_CASE_ARM_FIRES=$(( STRIP_CASE_ARM_FIRES + 1 ))
    MAYBE_STRIP_RESULT="$s"
    return 0
  fi
  MAYBE_STRIP_RESULT="$s"
  return 0
}

# Paren-type stack walker (r5 P1 BLOCKING fix). Walks the stripped line
# character-by-character and maintains the global `CAPTURE_STACK` — a
# string of single-char tokens:
#   'C'  capture wrapper (`$(`) — entry_capture turns ON while one is
#        anywhere in the stack.
#   'G'  bare group (`(`, including the inner `(` of arithmetic `((` and
#        `$((`) — does NOT count as capture, but takes up a slot so a
#        later `)` pops THIS group, not the enclosing capture.
#
# `)` pops the top (last char). Empty-stack pops are silent — that's the
# case-arm `)` (already stripped above), or a parser error in the source,
# neither of which should drag a REAL capture down to 0 the way the
# r3/r4 simple counter did (codex PR #954 r4 P1 BLOCKING).
#
# Why a stack instead of `capture_depth - close_count`: a bare `( cmd )`
# group emits an unmatched `)` from the simple counter's perspective —
# the `(` was not a `$(` open so it didn't increment, but the `)`
# decrements. r3/r4's clamp-to-0 masks the underflow but lets a `( cmd )`
# group line silently zero out a prior `$(` capture, dropping
# entry_capture on the next line's heredoc and bypassing the C1 guard.
# A stack tracks "what kind of paren most recently opened" so `)` pops
# the right one. Arithmetic `$((`/`((`/`))` balance naturally: each `(`
# pushes (C or G), each `)` pops; equal counts on the same line cancel.
#
# Reads STRIP_RESULT (post strip_quotes_and_comments + maybe_strip_case_arm)
# and mutates CAPTURE_STACK in place.
CAPTURE_STACK=""
update_capture_stack() {
  local s="$1"
  local n=${#s}
  local i=0
  local ch next
  while (( i < n )); do
    ch="${s:i:1}"
    # `$(` opens a CAPTURE — consume both chars and push C.
    if [[ "$ch" == '$' && $((i + 1)) -lt $n ]]; then
      next="${s:i+1:1}"
      if [[ "$next" == '(' ]]; then
        CAPTURE_STACK="${CAPTURE_STACK}C"
        i=$((i + 2))
        continue
      fi
    fi
    # Bare `(` (not preceded by `$`) opens a GROUP. Also covers the
    # inner `(` of arithmetic `$((` (first `(` already consumed as part
    # of `$(` push) and `((` (both pushes are GROUP).
    if [[ "$ch" == '(' ]]; then
      CAPTURE_STACK="${CAPTURE_STACK}G"
      i=$((i + 1))
      continue
    fi
    # `)` pops top of stack — empty-stack pop is silent.
    if [[ "$ch" == ')' ]]; then
      if [[ -n "$CAPTURE_STACK" ]]; then
        CAPTURE_STACK="${CAPTURE_STACK%?}"
      fi
      i=$((i + 1))
      continue
    fi
    i=$((i + 1))
  done
}

# Pull the heredoc delimiter token from a line. Echoes empty if no heredoc
# operator is present. Recognizes `<<DELIM`, `<<'DELIM'`, `<<"DELIM"`,
# `<<-DELIM`, and (per r3 P2 #2) optional whitespace after the operator.
#
# Bash regex backreferences inside `[[ =~ ]]` are unreliable, so we try
# the three quote variants explicitly instead of `(["'])(...)\1`. Always
# returns 0 — callers gate further work on the echoed token being
# non-empty (matters under `set -e`).
extract_heredoc_delim() {
  local line="$1"
  local re_sq='<<-?[[:space:]]*'"'"'([A-Za-z_][A-Za-z0-9_]*)'"'"
  local re_dq='<<-?[[:space:]]*"([A-Za-z_][A-Za-z0-9_]*)"'
  local re_nq='<<-?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)'
  if [[ "$line" =~ $re_sq ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$line" =~ $re_dq ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$line" =~ $re_nq ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf ''
  return 0
}

# ---------------------------------------------------------------------------
# Walk every source file line-by-line.
# ---------------------------------------------------------------------------

emit_tsv_header() {
  printf 'path\tline\tcategory\tsnippet_hash\treason\tsnippet\n'
}

emit_row_tsv() {
  local path="$1" line="$2" category="$3" hash="$4" reason="$5" snippet="$6"
  local safe="${snippet//$'\t'/ }"
  safe="${safe//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$path" "$line" "$category" "$hash" "$reason" "$safe"
}

emit_row_json() {
  local path="$1" line="$2" category="$3" hash="$4" reason="$5" snippet="$6"
  printf '{"path":%s,"line":%s,"category":%s,"snippet_hash":%s,"reason":%s,"snippet":%s}\n' \
    "$(json_escape "$path")" \
    "$line" \
    "$(json_escape "$category")" \
    "$(json_escape "$hash")" \
    "$(json_escape "$reason")" \
    "$(json_escape "$snippet")"
}

declare -A SUMMARY_COUNTS=( [C1]=0 [C2]=0 [C3]=0 [C4]=0 [H3]=0 [SAFE]=0 )

scan_file() {
  local rel="$1"
  local abs="$repo_root/$rel"
  [[ -f "$abs" ]] || return 0

  local lineno=0
  local raw norm_snippet hash class category reason
  # Cross-line capture state:
  #   CAPTURE_STACK   — global string of 'C' (capture) / 'G' (group) tokens
  #                     pushed/popped by update_capture_stack on each
  #                     line's stripped content. Reset per-file. r5
  #                     replaced the prior `capture_depth` integer counter
  #                     because the counter clamp-to-0 silently dragged a
  #                     real `$(` capture down whenever a bare `( cmd )`
  #                     group, `(( ))` arithmetic, or case-arm `)` shape
  #                     decremented past zero (codex PR #954 r4 P1
  #                     BLOCKING). The stack pops the RIGHT kind of paren
  #                     so each `)` cancels its matching `(` rather than
  #                     blindly eating the deepest `$(`.
  #                     entry_capture := CAPTURE_STACK contains 'C'.
  #   backtick_open   — 1 if an odd number of unescaped backticks have been
  #                     seen so far (we're inside a `…` capture). Tracked
  #                     separately from the paren stack because backticks
  #                     don't compose with `(` / `)`.
  #   in_heredoc_body — 1 while we're between a heredoc opener and its
  #                     terminating delimiter line. Paren tracking is
  #                     suspended in heredoc bodies (they're literal text,
  #                     not code).
  #   heredoc_delim   — the delimiter token we're waiting to see at the
  #                     start of a line to close the heredoc body.
  CAPTURE_STACK=""
  local backtick_open=0
  local in_heredoc_body=0
  local heredoc_delim=""
  local stripped ticks entry_capture trimmed delim
  # Quote state lives on STRIP_IN_SINGLE / STRIP_IN_DOUBLE and persists
  # across strip_quotes_and_comments() calls so multi-line `'...'`
  # arguments (e.g. `bash -c '\n  source ...\n  '`) don't bleed code into
  # the in-quote body. Reset at file boundaries.
  STRIP_IN_SINGLE=0
  STRIP_IN_DOUBLE=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))

    # Heredoc-body handling: skip paren / classification logic until we
    # see the line that closes the heredoc. The body terminator is the
    # delimiter token at the start of a line (leading whitespace tolerated
    # for the tab-strip `<<-` variant; we accept both shapes here because
    # the audit only needs to know where the body ENDS, not the exact
    # form of the opener).
    #
    # Backtick-wrapped heredoc (`var=\`cmd <<PY ... PY\``) puts the
    # closing backtick on the SAME line as the heredoc terminator, so we
    # also accept `<delim>` followed immediately by `` ` ``. (Other shapes
    # like `<delim>)` aren't legal — `$(...)` requires the `)` on its own
    # line after the terminator.)
    if (( in_heredoc_body == 1 )); then
      trimmed="${raw#"${raw%%[![:space:]]*}"}"
      local first_tok="${trimmed%%[[:space:]]*}"
      if [[ "$first_tok" == "$heredoc_delim" ]]; then
        in_heredoc_body=0
        heredoc_delim=""
      elif [[ "$first_tok" == "${heredoc_delim}\`" ]]; then
        in_heredoc_body=0
        heredoc_delim=""
        # Backtick terminator closes the surrounding backtick capture too.
        if (( backtick_open == 1 )); then
          backtick_open=0
        fi
      fi
      continue
    fi

    # Comment-only or empty lines: do NOT touch any cross-line state.
    # Comments can mention `<<'EOF'` or `$(...)` literally; treating them
    # as code would corrupt capture_depth and falsely enter heredoc body.
    trimmed="${raw#"${raw%%[![:space:]]*}"}"
    if [[ -z "$trimmed" || "$trimmed" == \#* ]]; then
      continue
    fi

    # Capture-state snapshot taken BEFORE the line's own deltas — that's
    # what classify_line cares about (was a `$(` from an EARLIER line still
    # open at the moment this heredoc opener was read?). entry_capture is
    # set when the CAPTURE_STACK contains any 'C' (capture) frame — bare
    # 'G' (group) frames don't count.
    if [[ "$CAPTURE_STACK" == *C* ]] || (( backtick_open == 1 )); then
      entry_capture=1
    else
      entry_capture=0
    fi

    if line_has_heredoc_like "$raw"; then
      class="$(classify_line "$raw" "$entry_capture")"
      category="${class%%|*}"
      reason="${class#*|}"
      case "$category" in
        NONE) ;;
        C1|C2|C3|C4|H3|SAFE)
          norm_snippet="$(normalize_snippet "$raw")"
          hash="$(printf '%s' "$norm_snippet" | _sha256)"

          SUMMARY_COUNTS[$category]=$(( ${SUMMARY_COUNTS[$category]:-0} + 1 ))

          case "$mode" in
            tsv)
              emit_row_tsv "$rel" "$lineno" "$category" "$hash" "$reason" "$norm_snippet"
              ;;
            json)
              emit_row_json "$rel" "$lineno" "$category" "$hash" "$reason" "$norm_snippet"
              ;;
            summary)
              : # counting only
              ;;
          esac
          ;;
        *) ;;
      esac
    fi

    # Update cross-line state from this line's own deltas. The stripped
    # form removes quoted strings and trailing comments so a `$(` inside
    # `'...'` / `"..."` or after `# ` doesn't push onto CAPTURE_STACK. We
    # use globals (STRIP_RESULT, MAYBE_STRIP_RESULT, COUNT_RESULT)
    # instead of $()-capture so the in_single / in_double / fires-counter
    # updates survive — $() spawns a subshell that discards the var writes.
    #
    # Snapshot the ENTRY quote state before strip mutates it. The
    # case-arm stripper needs entry-state, not post-strip-state, because
    # `pattern)` only legitimately appears at the start of a fresh shell
    # command (entry sgl=dbl=0). A continuation line inside a `$(python3
    # -c '...')` body sits at entry_dbl=1, and a Python tuple close like
    # `followup_sent_ts)` would otherwise match the case-arm regex and
    # get incorrectly stripped — eating the `)` that should pop the C
    # frame for the outer `$(`.
    local entry_in_single=$STRIP_IN_SINGLE
    local entry_in_double=$STRIP_IN_DOUBLE
    strip_quotes_and_comments "$raw"
    stripped="$STRIP_RESULT"
    # Case-arm `pattern)` at line start has no matching `(`. Without
    # stripping, its trailing `)` would pop the top of CAPTURE_STACK
    # (the r5 paren-type stack's empty-stack tolerance means an isolated
    # case-arm `)` is silent, but a REAL prior `$(`-pushed 'C' frame
    # would be eaten — codex PR #954 r3 finding P1 BLOCKING, which
    # bypassed the CI ratchet). Stripping the leading `pattern)` shape
    # BEFORE the stack walk preserves the capture frame intact across
    # case branches. maybe_strip_case_arm writes its result to
    # MAYBE_STRIP_RESULT (not stdout) so the STRIP_CASE_ARM_FIRES debug
    # counter increment survives — calling it via `$()` would discard
    # the counter update (r5 P2 verification hook).
    #
    # Guard: only invoke the case-arm stripper when the ENTRY quote state
    # is clean (sgl=dbl=0). Inside a multi-line `'...'` or `"..."` body
    # — most commonly a `python3 -c '...'` continuation under `$()` —
    # a regex match against the stripped output can falsely trigger on
    # interpreter syntax like `tuple_member)` and erase the `)` that
    # should pop the C frame for the outer capture (r5 self-test
    # regression discovered while validating the paren-type stack).
    if (( entry_in_single == 0 && entry_in_double == 0 )); then
      maybe_strip_case_arm "$stripped"
      stripped="$MAYBE_STRIP_RESULT"
    fi
    # Paren-type stack walk: pushes 'C' on `$(`, 'G' on bare `(`, pops
    # top on `)`. Empty-stack pops are silent (case-arm fallthrough or
    # source parser error). See update_capture_stack header for why a
    # stack is required instead of the r3/r4 simple counter.
    update_capture_stack "$stripped"
    count_backticks "$stripped"
    ticks="$COUNT_RESULT"
    if (( ticks > 0 )); then
      backtick_open=$(( (backtick_open + ticks) % 2 ))
    fi

    # Enter heredoc-body mode if this line opened a heredoc. We probe the
    # ORIGINAL raw line for the operator+delimiter (the stripped form may
    # have lost the delim if it was single-quoted, e.g. `<<'PY'`).
    if [[ "$raw" =~ $RE_HEREDOC_OP ]]; then
      delim="$(extract_heredoc_delim "$raw")"
      if [[ -n "$delim" ]]; then
        in_heredoc_body=1
        heredoc_delim="$delim"
      fi
    fi
  done < "$abs"
}

main() {
  if [[ "$mode" == "tsv" ]]; then
    emit_tsv_header
  fi

  local rel
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    # Skip self and the lint/self-test files — they contain fixture
    # patterns by design and would otherwise pollute the baseline.
    case "$rel" in
      scripts/audit-footgun-11.sh) continue ;;
      scripts/lint-heredoc-ban.sh) continue ;;
      scripts/smoke/lint-heredoc-scanner-self.sh) continue ;;
      # Static fixtures used by the scanner self-test (r2 fix for codex
      # PR #954 finding P1 #2 — the prior fixture was inlined via
      # `cat <<'FIXTURE'`, which wedges on Bash 5.3.9 footgun #11).
      scripts/smoke/lint-heredoc-fixtures/*) continue ;;
    esac
    scan_file "$rel"
  done < <(collect_sources)

  if [[ "$mode" == "summary" ]]; then
    printf 'category\tcount\n'
    for c in C1 C2 C3 C4 H3 SAFE; do
      printf '%s\t%s\n' "$c" "${SUMMARY_COUNTS[$c]:-0}"
    done
    local total=0
    for c in C1 C2 C3 C4 H3 SAFE; do
      total=$(( total + ${SUMMARY_COUNTS[$c]:-0} ))
    done
    printf 'TOTAL\t%s\n' "$total"
  fi

  # r5 P2: optional debug counter. When BRIDGE_AUDIT_DEBUG_CASE_ARM=1 is
  # set, emit the number of maybe_strip_case_arm invocations that
  # actually stripped something. The smoke self-test asserts this is
  # non-zero on the fixture to prove the strip ran in real code (not
  # just that the classification result is correct, which could happen
  # even if the strip silently no-op'd). Printed to stderr so it doesn't
  # pollute --tsv / --json / --summary stdout.
  if [[ "${BRIDGE_AUDIT_DEBUG_CASE_ARM:-0}" == "1" ]]; then
    printf 'STRIP_CASE_ARM_FIRES=%d\n' "$STRIP_CASE_ARM_FIRES" >&2
  fi
}

main "$@"
