#!/bin/bash
# shellcheck disable=SC2162
# Wiki daily hygiene check — patch가 cron으로 실행.
# CRITICAL/HIGH 발견 시 patch inbox에 task.

set -u
WIKI=~/.agent-bridge/shared/wiki
DATE=$(date +%Y-%m-%d)
LOG="$WIKI/_audit/daily-$DATE.md"
mkdir -p "$(dirname "$LOG")"

# 수치 수집
total_md=$(find "$WIKI" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
total_links=$(grep -roE '\[\[[^]]+\]\]' "$WIKI" --include='*.md' 2>/dev/null | wc -l | tr -d ' ')

# Entity-like 파일 frontmatter coverage
entity_files=$(find "$WIKI/agents" \( -path '*/entities/*.md' -o -path '*/concepts/*.md' -o -path '*/decisions/*.md' -o -path '*/systems/*.md' -o -path '*/papers/*.md' -o -path '*/ingredients/*.md' -o -path '*/frameworks/*.md' -o -path '*/regulations/*.md' -o -path '*/competitors/*.md' -o -path '*/products/*.md' -o -path '*/trends/*.md' -o -path '*/reviews/*.md' \) 2>/dev/null)
total_entity=$(echo "$entity_files" | grep -c '\S')
frontmatter_ok=$(echo "$entity_files" | while read f; do [ -z "$f" ] && continue; head -1 "$f" | grep -q '^---$' && echo ok; done | wc -l | tr -d ' ')
frontmatter_missing=$((total_entity - frontmatter_ok))

# Tree edge 잔존
people_anchor=$(grep -r '\[\[people#' "$WIKI" --include='*.md' --exclude-dir=_workspace --exclude-dir=_audit 2>/dev/null | wc -l | tr -d ' ')
agent_self=$(grep -rE '\[\[agents#[a-z-]+' "$WIKI/agents" --include='*.md' --exclude-dir=_workspace --exclude-dir=_audit 2>/dev/null | wc -l | tr -d ' ')
summary_tree=$(grep -rE '\[\[[a-z-]+-(weekly|monthly)-summary\]\]' "$WIKI/agents/*/daily" --include='*.md' --exclude-dir=_workspace --exclude-dir=_audit 2>/dev/null | wc -l | tr -d ' ')

# Per-agent index antipattern
per_agent_index=$(find "$WIKI/agents" -name 'index.md' 2>/dev/null | wc -l | tr -d ' ')

# Stem collision
top_collision=$(find "$WIKI" -name '*.md' -exec basename {} .md \; 2>/dev/null | sort | uniq -c | sort -rn | awk '$1 >= 3' | head -10)

# Orphan entities (참조 0건)
# (heavy — skip by default, enable with --full)

# 리포트 작성
{
  echo "# Wiki Daily Hygiene — $DATE"
  echo ""
  echo "## Counts"
  echo "- Total .md: $total_md"
  echo "- Wiki links: $total_links"
  echo "- Entity-like files: $total_entity"
  echo ""
  echo "## Frontmatter coverage"
  echo "- OK: $frontmatter_ok / $total_entity"
  echo "- Missing: $frontmatter_missing"
  echo ""
  echo "## Tree edge residuals (금지)"
  echo "- [[people#…]]: $people_anchor"
  echo "- [[agents#<self>…]]: $agent_self"
  echo "- daily→weekly/monthly-summary: $summary_tree"
  echo ""
  echo "## Per-agent index antipattern"
  echo "- per-agent index files: $per_agent_index (should be 0)"
  echo ""
  echo "## Stem collision (>= 3 occurrences)"
  echo '```'
  [ -n "$top_collision" ] && echo "$top_collision" || echo "(none)"
  echo '```'
} > "$LOG"

# CRITICAL 판정
critical_count=0
[ "$frontmatter_missing" -gt 0 ] && critical_count=$((critical_count + 1))
[ "$people_anchor" -gt 0 ] && critical_count=$((critical_count + 1))
[ "$agent_self" -gt 0 ] && critical_count=$((critical_count + 1))
[ "$summary_tree" -gt 0 ] && critical_count=$((critical_count + 1))
[ "$per_agent_index" -gt 0 ] && critical_count=$((critical_count + 1))

if [ "$critical_count" -gt 0 ]; then
  ADMIN="${BRIDGE_ADMIN_AGENT:-${BRIDGE_ADMIN_AGENT_ID:-patch}}"
  "${BRIDGE_AGB:-$HOME/.agent-bridge/agent-bridge}" task create \
    --to "$ADMIN" --priority high --from "$ADMIN" \
    --title "[wiki-daily-hygiene] CRITICAL ${critical_count}건 — $DATE" \
    --body-file "$LOG" >/dev/null 2>&1 || true
fi

echo "wiki-daily-hygiene: log=$LOG critical=$critical_count frontmatter_missing=$frontmatter_missing tree_edge=$((people_anchor + agent_self + summary_tree)) per_agent_index=$per_agent_index"
