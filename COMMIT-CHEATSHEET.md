# Commit Message Cheatsheet

Keep this visible when committing to public repos.

## Before Every Commit

```bash
# Run audit to check recent commits
./audit-commits.sh

# Commit will be auto-checked by hook
git commit -m "feat: your message here"
```

## Quick Reference

### ✅ USE THESE WORDS

```
add, create, implement, build
remove, delete, clean up
fix, resolve, correct, repair
improve, enhance, optimize, refine
update, modify, change, adjust
refactor, restructure, reorganize
docs, documentation
style, format
test, testing
perf, performance
chore, maintenance
```

### ❌ NEVER USE THESE

```
conversion, convert users, funnel
strategy, tactic, growth hack
gate, gating, lock, paywall
addiction, addictive, hook
FOMO, scarcity, urgency
AI agent, cursor, claude, chatgpt
teaser, maximize, monetize
churn, retention strategy
viral, manipulate, CTA
```

## Templates

### Features
```
✓ feat: add user authentication
✓ feat: implement audit history
✓ feat: add export functionality
```

### Fixes
```
✓ fix: resolve calculation error
✓ fix: correct API response format
✓ fix: handle edge case in parser
```

### Improvements
```
✓ improve: enhance dashboard performance
✓ improve: optimize query speed
✓ improve: simplify user flow
```

### Documentation
```
✓ docs: update README examples
✓ docs: add installation guide
✓ docs: clarify API usage
```

## Emergency Check

Before pushing to public repos:

```bash
# 1. Is this repo public?
git remote -v

# 2. Are my commits clean?
./audit-commits.sh

# 3. Review last 5 commits
git log --oneline -5

# 4. All clear? Push!
git push
```

---

**Golden Rule**: Describe WHAT changed, not WHY (business-wise)

