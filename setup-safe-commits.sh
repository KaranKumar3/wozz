#!/bin/bash

# Safe Commit Setup Script
# Run this in any Wozz repository to protect against strategy leaks

set -e

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

echo "🔒 Setting up safe commit guards..."
echo ""

# 1. Create commit-msg hook
echo "→ Installing commit-msg hook..."
cat > "$REPO_ROOT/.git/hooks/commit-msg" << 'EOF'
#!/bin/bash

COMMIT_MSG_FILE=$1
COMMIT_MSG=$(cat "$COMMIT_MSG_FILE")

FORBIDDEN_WORDS=(
    "conversion" "convert users" "strategy" "teaser" "gate" "gating"
    "hook users" "addictive" "addiction" "funnel" "viral" "growth hack"
    "AI agent" "cursor" "claude" "chatgpt" "prompt" "maximize" "monetize"
    "upsell" "saasy" "salesy" "marketing copy" "CTA" "call to action"
    "lock behind" "hide details" "paywall" "trial strategy" "churn"
    "retention strategy" "FOMO" "scarcity" "urgency" "manipulate"
)

for word in "${FORBIDDEN_WORDS[@]}"; do
    if echo "$COMMIT_MSG" | grep -iq "$word"; then
        echo ""
        echo "❌ COMMIT BLOCKED: Contains '$word'"
        echo ""
        echo "Your message: $COMMIT_MSG"
        echo ""
        echo "Use professional language instead:"
        echo "  ✓ improve, enhance, refactor, fix, add, update"
        echo ""
        exit 1
    fi
done

if [ ${#COMMIT_MSG} -gt 200 ]; then
    echo "⚠️  Commit message is long. Keep it vague and short."
fi

exit 0
EOF

chmod +x "$REPO_ROOT/.git/hooks/commit-msg"
echo "  ✓ commit-msg hook installed"

# 2. Create pre-push hook
echo "→ Installing pre-push hook..."
cat > "$REPO_ROOT/.git/hooks/pre-push" << 'EOF'
#!/bin/bash

echo ""
echo "🔍 Reviewing commits before push..."

COMMITS=$(git log --format=%s @{u}.. 2>/dev/null || git log --format=%s -5)

if [ -z "$COMMITS" ]; then
    echo "✓ No new commits"
    exit 0
fi

echo "$COMMITS" | head -10

FORBIDDEN=("conversion" "strategy" "teaser" "AI agent" "hook users" "addiction" "gate" "viral" "FOMO")

FOUND_ISSUE=false
for pattern in "${FORBIDDEN[@]}"; do
    if echo "$COMMITS" | grep -iq "$pattern"; then
        echo "❌ FOUND: '$pattern'"
        FOUND_ISSUE=true
    fi
done

if [ "$FOUND_ISSUE" = true ]; then
    echo ""
    echo "❌ PUSH BLOCKED: Strategy leak detected"
    echo ""
    echo "Fix: git commit --amend or git rebase -i HEAD~N"
    echo ""
    exit 1
fi

echo "✓ All commits look clean"
echo ""
exit 0
EOF

chmod +x "$REPO_ROOT/.git/hooks/pre-push"
echo "  ✓ pre-push hook installed"

# 3. Create commit message template
echo "→ Installing commit template..."
cat > "$REPO_ROOT/.gitmessage" << 'EOF'
# <type>: <subject>

# Types: feat, fix, docs, style, refactor, perf, test, chore

# GOOD (professional & vague):
#   ✓ feat: add metrics collection
#   ✓ improve: enhance UI performance
#   ✓ fix: resolve calculation bug
#   ✓ docs: update installation steps

# BAD (reveals strategy):
#   ✗ feat: add conversion funnel
#   ✗ improve: make more addictive
#   ✗ feat: gate features for trial

# Rules:
#   - Under 72 chars
#   - Vague but accurate
#   - No: conversion, strategy, AI, gating, addiction, FOMO
EOF

git config commit.template .gitmessage
echo "  ✓ commit template configured"

echo ""
echo "✅ Safe commit system installed!"
echo ""
echo "This repo is now protected from strategy leaks."
echo ""
echo "Test it:"
echo "  git commit -m 'feat: add conversion funnel'  # Will be blocked"
echo "  git commit -m 'feat: add user dashboard'     # Will succeed"
echo ""

