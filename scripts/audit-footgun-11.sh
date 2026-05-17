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
RE_HEREDOC_OP='<<-?["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?'
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
classify_line() {
  local line="$1"
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
  if is_output_file_heredoc "$line"; then
    printf 'SAFE|write-to-file heredoc (cmd > path <<EOF)\n'
    return
  fi

  local in_cap=0
  if in_capture_line "$line"; then
    in_cap=1
  fi

  if (( in_cap == 1 )) && [[ "$line" =~ $RE_CAT_HEREDOC ]]; then
    printf 'C2|cat heredoc in capture\n'
    return
  fi
  if (( in_cap == 1 )); then
    if [[ "$line" =~ $RE_INTERP ]]; then
      printf 'C1|interpreter heredoc in capture (deadlock class)\n'
    else
      printf 'C1|heredoc in capture\n'
    fi
    return
  fi

  # Outside capture.
  if [[ "$line" =~ $RE_BASH_S ]] && [[ "$line" =~ $RE_HEREDOC_OP ]]; then
    printf 'C4|bash -s heredoc, no capture\n'
    return
  fi
  if [[ "$line" =~ $RE_INTERP ]]; then
    printf 'C3|interpreter heredoc, no capture\n'
    return
  fi

  printf 'SAFE|non-interpreter heredoc, no capture\n'
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
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    if ! line_has_heredoc_like "$raw"; then
      continue
    fi
    class="$(classify_line "$raw")"
    category="${class%%|*}"
    reason="${class#*|}"
    case "$category" in
      NONE) continue ;;
      C1|C2|C3|C4|H3|SAFE) ;;
      *) continue ;;
    esac

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
}

main "$@"
