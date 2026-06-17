# Decision Log — 2026-06-17

## Session Context
Current goal was to produce a comprehensive plan for getting windowing working in gamescope mode and controller isolation working on Steam Deck. The user requested the plan be challenged and refined 3x before presenting for review.

## Key Decisions Made

### 1. Windowing Approach
**Decision:** Test xdotool geometry in gamescope directly as first step. No code changes needed to test.

**Ruling out Xephyr** — Xephyr was considered (adds a nested X server that provides a standard X11 WM where xdotool definitely works) but deferred because:
- Adds one package dependency (`Xephyr`)
- Adds compositing latency (~1 frame)
- May not be available on SteamOS or may require additional permissions

**Why the Splitscreen mod alone isn't enough:** The mod controls the Minecraft **viewport** (which portion of the screen to render), not the **OS window bounds**. Both Minecraft windows are fullscreen 1920×1080 stacked at (0,0). The mod renders BOTTOM content in a fullscreen window on top — you still only see the top window. Windows must be physically repositioned for the split to be visible.

### 2. Controller Isolation — The One Session That Worked
**Decision:** Restore the exact SDL env configuration from the one successful session and add the Deck built-in event node masking.

**The critical mistake that broke things:** Adding `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=0` tells SDL3 to explicitly **exclude `28de:11ff` devices from all backends including evdev**. The Steam virtual Xbox pads ARE `28de:11ff`. This made the only device in the sandbox invisible to SDL.

**The env var fix:**
- `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1` — let SDL see the virtual pad
- `SDL_GAMECONTROLLER_IGNORE_DEVICES=` — clear Steam's DS4 exclusion list
- `SDL_JOYSTICK_HIDAPI=0` — no hidraw needed (virtual pads have none)

**The missing piece:** The Deck built-in is also `28de:11ff`. With `--dev-bind /run /run`, Steam's IPC socket is exposed, and with `ALLOW_STEAM_VIRTUAL=1`, SDL can see all controllers through it. Fix: extract the Deck built-in's event node from `_identify_internal_virtual_index()` and mask it with `--bind /dev/null` in every sandbox.

### 3. Prioritization
**Decision:** Fix windowing first if xdotool test is fast, otherwise use the quick controller fix to enable testing of both.

### 4. No External Dependencies (for now)
Xephyr is deferred until/unless xdotool is proven non-functional in gamescope. All current planned changes use existing tools (bwrap, xdotool, SDL env vars, bash, jq).

## What We Know vs What We Assume

| Statement | Status | Source |
|-----------|--------|--------|
| `xdotool set_window --name` doesn't persist in gamescope | **Known fact** | Confirmed in session log (grep for "Minecraft* 26.1.2") |
| `xdotool windowmove/windowsize` may also be ignored | **Assumption** | Not yet tested in isolation |
| Splitscreen mod controls viewport only, not window bounds | **Known fact** | All session empirical data confirms this |
| The one working controller config had these 3 SDL env vars | **Known fact** | Session 2026-06-16 ~23:25-23:31 |
| Steam sets `SDL_GAMECONTROLLER_IGNORE_DEVICES` with DS4 PIDs | **Known fact** | Confirmed from `/proc/<bwrap>/environ` |
| `--dev-bind /run /run` exposes Steam IPC socket | **Known fact** | Confirmed from `/proc/<bwrap>/environ` SDL env vars |
| Xephyr works in gamescope | **Assumption** | Not tested, but well-established Linux tech |
| Deck built-in event node can be extracted from `_identify_internal_virtual_index()` | **Known fact** | Function exists and works |

## Open Questions

1. **Does xdotool windowmove/windowsize work in gamescope's XWayland?** — Must be tested. The plan's first actionable step.
2. **Can we do the xdotool test without launching Minecraft?** — Yes, GTK test windows work. Only requires SSH access while a gamescope session is active.
3. **Will the controller fix also work in handheld mode?** — Should, since handheld also uses `SDL_JOYSTICK_HIDAPI=0` and the Deck built-in's event node is bound normally. The mask of the built-in is a no-op when there's only one instance.
4. **Is Xephyr available on SteamOS without extra packages?** — Unknown. Need to check `pacman -Q xephyr` or equivalent.

## Repository References

| File | Content |
|------|---------|
| `GAMESCOPE-WINDOWING.md` | Main work log — architecture, what works, commit history |
| `PLAN-WINDOWING-CONTROLLERS.md` | Full comprehensive plan with 3-round challenge/refine (this session) |
| `SESSION-2026-06-16.md` | Raw full session log from previous work session |

## Files to Modify When Implementing

| File | Change | Priority |
|------|--------|----------|
| `modules/instance_lifecycle.sh` — `_build_bwrap_command()` | Add 4 SDL env vars, mask Deck built-in event node | High |
| `modules/instance_lifecycle.sh` — `spawn_instance()` | Optional: sequential spawn timing fix | Medium |
| `minecraftSplitscreen.sh` — `docked_flow()` | Optional: background layout loop (if xdotool works) | Medium |
| `modules/window_manager.sh` — `apply_layout()` | Verify WID-from-state lookup is correct | Low (already done) |
