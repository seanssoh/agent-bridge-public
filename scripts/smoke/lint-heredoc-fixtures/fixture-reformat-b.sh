#!/usr/bin/env bash
out=$(python3   -   "$payload"   <<'PY'
print(1)
PY
)
