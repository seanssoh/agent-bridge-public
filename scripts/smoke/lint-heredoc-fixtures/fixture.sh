#!/usr/bin/env bash
# Comment line: bash -s -- <<'EOF' (NEG: comment should never match).
# Comment line: $(python3 - <<'PY')  (NEG: comment should never match).

# C3: interpreter heredoc outside capture, single quoted delimiter.
python3 - "$payload" <<'PY'
print("hello")
PY

# C3: interpreter heredoc outside capture, unquoted delimiter, tab-strip.
python3 - <<-PY
print("indent ok")
PY

# C3: arbitrary delimiter MARKER must be matched (regex must not hard-code EOF/PY).
python3 - <<MARKER
print("marker delim")
MARKER

# C4: bash -s heredoc, no capture.
bash -s -- "$arg" <<'EOF'
echo hi
EOF

# C1: nested $() with python3 - heredoc.
out=$(python3 - "$payload" <<'PY'
print("captured")
PY
)

# C1: env-prefixed python3 inside $().
result="$(NOTE='x' python3 - <<'PY'
print(1)
PY
)"

# C1: pipe-then-capture (printf | python3 - <<PY inside $()).
result="$(printf '%s' "$json" | python3 - "$arg" <<'PY'
print(2)
PY
)"

# C1: backtick wrapper, single-quoted delimiter.
backtick=`python3 - "$payload" <<'PY'
print(3)
PY`

# C2: cat heredoc inside $() capture.
content="$(cat <<EOF
template
EOF
)"

# SAFE: write-to-file heredoc with cat > path syntax.
cat > "$tmp_path" <<EOF
template
EOF

# SAFE: cat <<EOF top-level (usage/help text).
cat <<EOF
usage: smoke
EOF

# SAFE: redirected to stderr (still a write-target, not a capture).
cat > /dev/stderr <<EOF
msg
EOF

# H3: here-string feeding read.
IFS=$'\t' read -r a b c <<<"$row"

# H3: here-string feeding python3 (interpreter consumer flag).
result="$(python3 -c 'import sys;print(sys.stdin.read())' <<<"$payload")"

# H3: stdin redirected from process substitution (`< <(...)`).
while IFS= read -r line; do :; done < <(echo a)

# C3: heredoc operator with whitespace before delimiter (Bash-legal).
# r3 fixture for codex PR #954 r2 finding P2 #2 — the original regex
# required `<<DELIM` with no gap and silently dropped `<<  'PY'`.
python3 - "$payload" <<  'PY'
print("space-before-delim")
PY

# C1: cross-line capture — `$(` opens on line 85, heredoc opens on line 87
# inside the still-open capture. Before r3 the classifier only looked at
# the single line of the heredoc and tagged this as C3, letting a copy of
# a baselined C3 site wrapped in multi-line capture slip past
# --baseline-check (codex PR #954 r2 finding P1).
out=$(
  bridge_require_python
  python3 - "$payload" <<'PY'
print("cross-line capture")
PY
)

# C1: cross-line capture with backtick wrapper variant.
out=`
  python3 - "$payload" <<'PY'
print("cross-line backtick")
PY`
