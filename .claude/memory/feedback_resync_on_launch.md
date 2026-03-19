---
name: Resync repo on every session start
description: Always run git fetch + fast-forward pull at the start of every conversation to sync local main with origin/main
type: feedback
---

At the start of every conversation, always resync the local repo with the remote before doing any work:

```bash
git fetch origin && git pull --ff-only origin main
```

**Why:** Remote may have commits (from other sessions, devices, or direct GitHub edits) that aren't local yet. Working on a stale local copy causes merge conflicts and confusing divergence later.

**How to apply:** Run this as the very first action in every new conversation, before reading any files or making any changes.
