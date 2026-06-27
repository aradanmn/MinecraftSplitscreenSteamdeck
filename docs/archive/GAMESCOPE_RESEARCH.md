# Gamescope Window Management Research

**Question:** Can we use Gamescope's native window management instead of KWin scripts for borderless splitscreen?

**Short Answer:** No - Gamescope is designed for single-window compositing, not splitscreen layouts.

---

## Research Findings

### What Gamescope Is Designed For

Gamescope is Valve's Wayland compositor optimized for **single game window** scenarios:
- Upscaling/downscaling a single game window
- HDR support
- Framerate limiting
- FSR/NIS filtering
- VR overlays

**Key limitation:** Gamescope focuses on compositing ONE window at a time.

### Multiple Windows in Gamescope

According to [GitHub Issue #437](https://github.com/ValveSoftware/gamescope/issues/437):
> "When running applications that have multiple windows, Gamescope gets confused and rapidly switches between those windows."

**Problem:** Gamescope doesn't have native multi-window tiling or splitscreen layout support.

### Relevant Gamescope Options

**Window control flags:**
- `--force-windows-fullscreen` - Force windows to fill nested display
- `-b, --borderless` - Make window borderless (nested mode)
- `-f, --fullscreen` - Make window fullscreen (nested mode)

**But:** These apply to the single composited window, not multiple windows in a grid.

### Multiple Xwayland Instances (`--xwayland-count`)

From [GitHub Issue #803](https://github.com/ValveSoftware/gamescope/issues/803):
- `--xwayland-count N` creates N isolated Xwayland servers
- Used for **isolation** (e.g., Steam overlay vs game), not splitscreen
- Multiple instances don't render in grid layout

### Could We Run Multiple Gamescope Instances?

**Theory:** Run 4 Gamescope instances, each with 1 Minecraft window, position them in a grid.

**Problems:**
1. Each Gamescope instance needs its own display/output
2. [Nested Gamescope causes stuttering](https://github.com/Plagman/gamescope/issues/452)
3. No built-in coordination between instances
4. Would need external window manager to position 4 Gamescope windows
5. Much more complex than current approach

### Feature Requests

From [GitHub Issue #753](https://github.com/Plagman/gamescope/issues/753):
> "It would be powerful to support exposing multiple nested monitors for applications which produce two game windows"

**Status:** Requested feature, not yet implemented.

---

## Conclusions

### Why We Can't Use Gamescope for Splitscreen

1. **Single-window compositor** - Architectural limitation
2. **No multi-window tiling** - Not designed for this use case
3. **Multiple instances impractical** - Would need external positioning anyway
4. **Feature not implemented** - No roadmap for splitscreen support

### What Gamescope DOES Handle Well

When Gamescope is used (Game Mode):
- **Borderless fullscreen** - Native support
- **Vulkan layer management** - When hooks succeed
- **Display output** - HDR, scaling, filtering

**The issue:** Our Border Enforcer KWin script interferes with Gamescope's Vulkan layer initialization.

---

## Recommendation

**Keep KWin-based approach, fix the race condition:**

1. **Why KWin is appropriate:**
   - Desktop Mode: KWin is the window manager, natural fit
   - Game Mode: KWin script runs in nested Plasma OR we can skip repositioning
   - Mature, tested window positioning API
   - No need to reinvent window management

2. **Fix the Border Enforcer issue:**
   - Install Border Enforcer AFTER positioning (Solution 1)
   - OR disable in Game Mode entirely (Solution 2)
   - Both solutions preserve Gamescope's Vulkan layer hooking

3. **Let Gamescope do what it does best:**
   - Handle single-window compositing
   - Manage Vulkan layers without interference
   - Provide upscaling/HDR/framerate control

---

## Alternative: Simplify Game Mode Approach

**Observation:** In Game Mode (Gamescope), we might not need fancy window repositioning at all.

**Why?**
- Gamescope already provides borderless fullscreen via `--force-windows-fullscreen`
- The Splitscreen mod's `splitscreen.properties` handles the actual screen division
- KWin repositioning may be overkill in Gamescope environment

**Simplified approach:**
1. **Desktop Mode:** Use KWin scripts for borderless + positioning (works great)
2. **Game Mode:** Skip KWin scripts entirely, let Gamescope + Splitscreen mod handle it
   - Gamescope provides borderless fullscreen
   - Splitscreen mod divides the screen per instance config
   - No Border Enforcer needed (nothing to race with)

**This would:**
- Eliminate the race condition entirely
- Reduce complexity
- Rely on Valve-tested Gamescope behavior
- Still use KWin where appropriate (Desktop Mode)

---

## Proposed Solution: Conditional Window Management

```bash
# In runStaticSplitscreen() and runDynamicSplitscreen():

if isSteamDeckGameMode; then
    # Game Mode: Let Gamescope handle borderless, skip KWin scripts
    log_info "Game Mode: Using Gamescope native borderless, skipping KWin repositioning"
    # Just launch instances - Gamescope + splitscreen.properties handle the rest
else
    # Desktop Mode: Use KWin for positioning and borderless
    if canUseKWinScripting; then
        # Install Border Enforcer AFTER positioning (or skip if not needed)
        repositionAllWindows "$numberOfControllers"
        installBorderEnforcer  # Only in desktop mode, after positioning
    fi
fi
```

**Benefits:**
- No Gamescope interference (no KWin scripts in Game Mode)
- Uses native Gamescope borderless fullscreen
- Preserves KWin positioning for Desktop Mode
- Simple, clean separation of concerns

---

## Sources

- [Dealing with multiple windows · Issue #437 · ValveSoftware/gamescope](https://github.com/ValveSoftware/gamescope/issues/437)
- [Support multiple nested monitors · Issue #753 · ValveSoftware/gamescope](https://github.com/Plagman/gamescope/issues/753)
- [[ANV/Intel] Some intel devices won't render if --xwayland-count 2 is used · Issue #803](https://github.com/ValveSoftware/gamescope/issues/803)
- [Stuttering in-game with one gamescope instance nested inside another · Issue #452](https://github.com/Plagman/gamescope/issues/452)
- [Gamescope + Big Picture Overlay mouse recapture bug · Issue #2042](https://github.com/ValveSoftware/gamescope/issues/2042)
- [Gamescope - ArchWiki](https://wiki.archlinux.org/title/Gamescope)
- [GitHub - ValveSoftware/gamescope](https://github.com/ValveSoftware/gamescope)
