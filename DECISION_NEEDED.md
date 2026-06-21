# Decision Needed: How to Fix Gamescope Memory Leak

**Date:** 2026-02-09 (early morning while you slept)
**Status:** Research complete, awaiting your decision

---

## What You Asked

> "I'm wondering however if we should be using gamescope's borderless window management instead for desktop mode and gamescope mode. Since Valve and other teams have heavily tested it."

---

## Research Results: Gamescope Can't Do Splitscreen

**TL;DR:** Gamescope is designed for **single-window** compositing, not multi-window splitscreen layouts.

### Key Findings

1. **Gamescope is single-window only** - Architectural limitation
2. **Multiple windows cause confusion** - Rapidly switches between them
3. **No grid/tile layout support** - Not a feature
4. **Multiple instances impractical** - Stuttering, coordination issues

See `GAMESCOPE_RESEARCH.md` for full details and sources.

---

## Updated Recommendation: Simplest Solution

**Skip KWin scripts entirely in Game Mode, use them only in Desktop Mode.**

### Why This Works

**In Game Mode (Gamescope):**
- Gamescope already provides borderless fullscreen via `--force-windows-fullscreen`
- Splitscreen mod's `splitscreen.properties` divides the screen per instance
- **No KWin scripts = no race condition = no memory leak**
- Uses Valve-tested Gamescope behavior

**In Desktop Mode (KDE):**
- KWin scripts provide borderless + positioning
- Border Enforcer maintains state during gameplay
- Works perfectly (already tested successfully)

### Code Concept

```bash
if isSteamDeckGameMode; then
    # Game Mode: Skip all KWin scripts, let Gamescope handle it
    log_info "Game Mode: Using Gamescope native window management"
    # Just launch instances - Gamescope + splitscreen.properties do the rest
else
    # Desktop Mode: Use KWin for positioning
    repositionAllWindows "$numberOfControllers"
    installBorderEnforcer  # After positioning, desktop mode only
fi
```

**Benefits:**
- ✅ Eliminates race condition (no KWin scripts in Game Mode)
- ✅ Uses native Gamescope features (proven, tested)
- ✅ Preserves KWin positioning for Desktop Mode
- ✅ Simplest possible solution
- ✅ Clean separation of concerns

---

## All Options Available

### Option 1: Conditional KWin (RECOMMENDED - SIMPLEST)

**What:** Skip KWin scripts in Game Mode, use them in Desktop Mode only.

**Pros:**
- Simplest implementation
- No race condition possible
- Uses native Gamescope behavior
- Clean code

**Cons:**
- None identified

---

### Option 2: Delay Border Enforcer

**What:** Install Border Enforcer AFTER positioning in all modes.

**Pros:**
- Fixes race condition
- Preserves Border Enforcer everywhere
- Small code change

**Cons:**
- Still using KWin scripts in Game Mode (may be unnecessary)
- More complex than Option 1

---

### Option 3: Delay + Conditional (BELT AND SUSPENDERS)

**What:** Combine Option 1 and Option 2.

**Pros:**
- Maximum safety
- Works if Game Mode detection fails

**Cons:**
- More complex
- May be overkill

---

### Option 4: Just Disable Border Enforcer in Game Mode

**What:** Keep KWin repositioning, skip Border Enforcer in Game Mode.

**Pros:**
- Small change
- Fixes race condition

**Cons:**
- Still using KWin repositioning in Game Mode (may be unnecessary)

---

## My Recommendation

**Implement Option 1 (Conditional KWin)** because:

1. **Simplest** - Skip KWin entirely in Game Mode
2. **Uses Gamescope correctly** - Let it do what it does best
3. **No race condition** - Can't race if KWin scripts aren't running
4. **Already proven** - Rev2 worked without KWin scripts in Game Mode
5. **Clean architecture** - Right tool for each environment

### Implementation Plan

1. Add conditional check: `if ! isSteamDeckGameMode` before KWin script calls
2. Test in both Desktop Mode and Game Mode
3. Verify no memory leak in static mode
4. Commit and document

---

## Questions for You

1. **Do you agree with Option 1 (Conditional KWin)?**
   - Or prefer a different option?

2. **Should I implement it now?**
   - Or wait for more discussion?

3. **Testing approach:**
   - Hand off to Bazzite Claude for testing?
   - Test both modes?

---

## Files to Review

1. **`GAMESCOPE_RESEARCH.md`** - Full Gamescope research and sources
2. **`GAMESCOPE_INVESTIGATION.md`** - Original analysis (all 4 options)
3. **This file** - Summary and recommendation

---

## Current Status

✅ Root cause identified (Border Enforcer race condition)
✅ Dynamic mode default (commit a76bf34, pushed)
✅ Gamescope research complete (can't do splitscreen)
✅ Simplest solution identified (conditional KWin)
⏳ **Awaiting your decision to implement**

Sleep well! I'll be ready to implement whichever approach you prefer. 🌙
