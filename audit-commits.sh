#!/bin/bash

# Audit Existing Commits
# Run this periodically to check if any unpushed commits have strategy leaks

set -e

echo "🔍 COMMIT AUDIT REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check last 20 commits
RECENT_COMMITS=$(git log --format="%h %s" -20 2>/dev/null)

if [ -z "$RECENT_COMMITS" ]; then
    echo "✓ No commits to audit"
    exit 0
fi

echo "Last 20 commits:"
echo ""
echo "$RECENT_COMMITS"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Forbidden patterns
FORBIDDEN=(
    "conversion:Conversion strategy"
    "convert users:User conversion tactics"
    "teaser:Teaser/gating strategy"
    "strategy:Internal strategy"
    "AI agent:AI assistance mention"
    "cursor:AI tool mention"
    "claude:AI tool mention"
    "chatgpt:AI tool mention"
    "hook users:Manipulation tactics"
    "addictive:Addiction mechanics"
    "addiction:Addiction mechanics"
    "gate:Feature gating"
    "gating:Feature gating"
    "funnel:Conversion funnel"
    "viral:Viral growth tactics"
    "growth hack:Growth hacking"
    "FOMO:FOMO tactics"
    "maximize:Maximize conversion"
    "monetize:Monetization strategy"
    "churn:Churn strategy"
    "retention strategy:Retention tactics"
    "lock behind:Feature locking"
    "paywall:Paywall mention"
)

FOUND_ISSUES=()

# Check each pattern
for entry in "${FORBIDDEN[@]}"; do
    pattern="${entry%%:*}"
    description="${entry##*:}"
    
    if echo "$RECENT_COMMITS" | grep -iq "$pattern"; then
        FOUND_ISSUES+=("$description (keyword: $pattern)")
    fi
done

# Report
if [ ${#FOUND_ISSUES[@]} -gt 0 ]; then
    echo "❌ ISSUES FOUND:"
    echo ""
    for issue in "${FOUND_ISSUES[@]}"; do
        echo "  ⚠️  $issue"
    done
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "⚡ ACTION REQUIRED:"
    echo ""
    echo "  These commits should NOT be pushed to public repos."
    echo ""
    echo "  Options:"
    echo "    1. Rewrite history: git rebase -i HEAD~N"
    echo "    2. Amend last commit: git commit --amend"
    echo "    3. Reset and recommit with clean messages"
    echo ""
    echo "  After fixing, run this script again."
    echo ""
    exit 1
else
    echo "✅ ALL CLEAR"
    echo ""
    echo "No strategy leaks detected in recent commits."
    echo "Safe to push to public repositories."
    echo ""
fi

