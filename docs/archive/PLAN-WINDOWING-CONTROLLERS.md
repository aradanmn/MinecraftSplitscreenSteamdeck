# Challenge & Refine Log — Gamescope Windowing & Controller Isolation Plan

## Round 1: Challenge xdotool Dependency

### Original Plan Assumption
The plan assumed `xdotool windowmove/windowsize` is the right way to position windows inside gamescope, and that testing it from SSH is the first step.

### Research Findings
- **gamescope's XWayland is NOT a standard X11 window manager** — it's a direct compositor that uses Wayland surfaces, not X11 window decorations
- `xdotool` sends X11 `ConfigureRequest` events, which XWayland translates to Wayland surface dimensions/positions
- **gamescope may ignore these** — it composites "layers" based on its own understanding of which window is the "game"
- The `_NET_WM_STATE`, `OverrideRedirect`, and `WM_NAME` properties are translated inconsistently (confirmed: `set_window --name` doesn't stick)
- **The Splitscreen Support mod controls the VIEWPORT, not the WINDOW** — it renders only its assigned portion (TOP/BOTTOM/etc.) within a full-size window. So P2 renders bottom-half content but the window is still 1920×1080 and stacked on top of P1's window.

### Challenge
Relying on xdotool for window positioning inside gamescope is fragile and untested. The current architecture stacks two full-size windows, and the mod's viewport control is invisible because P2's window is on top.

### Refined Approach
**Remove xdotool from the critical path entirely.** Instead, use the **Splitscreen Support mod's native `splitscreen.properties`** combined with **window Z-order management**:

1. The mod already reads `mode=TOP`/`BOTTOM` from `splitscreen.properties`
2. Both windows are 1920×1080, but each renders only its half
3. The problem is they stack — only the top window is fully visible
4. **Fix: launch instances sequentially, not in parallel** — P1 launches first at fullscreen, then P2 launches. P2 covers the fullscreen with its BOTTOM viewport. Both are fully visible because the splitted viewport rendering shows both halves on top of each other... Wait, no — P2 is ON TOP of P1, so only P2 is visible.

**This doesn't work either** — splitting the viewport within fullscreen stacked windows doesn't help. They need different positions.

---

## Round 2: Challenge Architecture — Do We Need Window Positioning at All?

### Research Findings
- The Splitscreen Support mod reads `splitscreen.properties` at **launch time only** (confirmed from session logs — it doesn't re-read the file)
- The mod controls the **Minecraft rendering viewport**, not the OS window
- Both Minecraft instances are fullscreen 1920×1080 windows stacked on the same `(0,0)` position
- gamescope composites layers from bottom to top — whatever window is "last created" or "last focused" is on top
- The window on top blocks all view of the one below it, even if the mod renders only a portion

### Critical Insight
The mod splits the **rendered output** but not the **window bounds**. Two half-viewports inside two fullscreen stacked windows look identical to one fullscreen window. The only way to see both halves simultaneously is to **position the windows at different screen locations**.

### FIVE Approaches Ranked

| Approach | Complexity | Dependencies | Likelihood of Working |
|---|---|---|---|
| **1. Test xdotool in gamescope directly** (original plan) | Low | None | Unknown (must test) |
| **2. Xephyr nested X server** | Medium | `Xephyr` pkg (+1 dependency) | High — standard X11 WM inside |
| **3. Gamescope nested session** | High | Gamescope-specific | Unknown |
| **4. Create one fullscreen parent window with X11 children** | High | X11 programming | Medium |
| **5. Use the Steam overlay for second window** | Very High | Steam-specific | Low |

### Challenge Accepted
Approach 1 (test xdotool) is still the lowest-risk first step. BUT: **we can test xdotool in gamescope without running Minecraft at all.** We've confirmed Python3+GTK works. We can create test windows and verify xdotool geometry inside gamescope directly — a 30-second test.

### Refined Plan
1. Create two GTK test windows from SSH while in Game Mode
2. Run `xdotool getwindowgeometry` on each in a loop
3. Run `xdotool windowmove` and verify position changes stick
4. Read back geometry — if it changed, xdotool works; if not, we need Xephyr
5. Total test time: < 5 minutes (no Minecraft launch needed)

---

## Round 3: Challenge Controller Isolation — The Real Simplification

### Research Findings (from session data)
- The one session where controller isolation WORKED had: `SDL_JOYSTICK_HIDAPI=0` + `ALLOW_STEAM_VIRTUAL_GAMEPAD` inherited (1) + only one event/js file bound in `/dev/input/`
- When it broke: we added `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=0` (which blocks the ONLY device in the sandbox from being seen by SDL)
- ALSO: `SDL_GAMECONTROLLER_IGNORE_DEVICES` from Steam excludes DS4 VID/PIDs from evdev, which means even if the virtual pad is visible, SDL ignores the actual evdev node
- The Deck built-in (also `28de:11ff`) was leaking because Steam's IPC socket shows ALL controllers to ALL sandboxes

### The Core Insight We Missed
**The Steam virtual Xbox pad (`28de:11ff`) is the ONLY device in the bwrap sandbox** — `/dev/input/` only has the one event+js that was explicitly bound. SDL can't reach Steam's IPC socket if we control the env vars. The fix is just three env vars:

```bash
SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1   # Let SDL see the virtual pad
SDL_GAMECONTROLLER_IGNORE_DEVICES=                   # Clear DS4 exclusion — not needed for 28de:11ff
SDL_JOYSTICK_HIDAPI=0                                # No hidraw needed for virtual pads
```

- `ALLOW_STEAM_VIRTUAL_GAMEPAD=1`: lets SDL accept `28de:11ff` devices → the ONE we have
- `IGNORE_DEVICES=` (empty): ensures SDL doesn't skip our device based on VID:PID
- `HIDAPI=0`: no hidraw needed (virtual Xbox pads have none)

### Why the Deck built-in won't leak with these settings
- The Deck built-in is ALSO `28de:11ff`, but its event/node is NEVER bound in the bwrap sandbox
- With `ALLOW_STEAM_VIRTUAL_GAMEPAD=1`, SDL might try Steam IPC... BUT:
- We also need to **bind `--dev-bind /run /run`** (required for X11) — this exposes Steam's IPC socket
- The Steam socket exposes the Deck built-in too
- **Fix: explicitly mask the Deck built-in's event node** in every sandbox using `--bind /dev/null`

### The Missing Piece
We identify the Deck built-in via `_identify_internal_virtual_index()` but never extract its event node to mask it. Simple fix: after identifying the index, resolve that index to an event node, then pass it to `_build_bwrap_command` as an additional mask entry.

### Refined Final Plan

**Phase 1: Window Positioning** (2-step test, no code changes needed)
1. **Step 1: Test xdotool in gamescope** — SSH while in Game Mode, create 2 GTK test windows, verify xdotool geometry works
2. **If xdotool works**: fix timing — spawn instances sequentially (P1 first, wait for window, P2 second, wait for window, call apply_layout once)
3. **If xdotool doesn't work**: use Xephyr (small dependency, known behavior)

**Phase 2: Controller Isolation** (3 concrete code changes)
1. **Set exact SDL env vars** in bwrap: `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1`, `SDL_GAMECONTROLLER_IGNORE_DEVICES=`, `SDL_JOYSTICK_HIDAPI=0`
2. **Mask the Deck built-in's event node** in every bwrap sandbox (resolve from `_identify_internal_virtual_index()`)
3. **Remove `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=0`** (the bug that broke controllers)

**Phase 3: Verification & Robustness**
1. Verify handheld mode still works (same SDL env, same bwrap structure, single controller)
2. Run hardware test suite (stage3_hotplug, stage4_isolation)
3. Add `SPLITSCREEN_DIAGNOSE=1` mode for future debugging
