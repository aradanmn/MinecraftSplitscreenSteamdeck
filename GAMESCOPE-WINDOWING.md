# Gamescope Windowing — Work Log

Branch: `feat/gamescope-windowing`  
Goal: Two Minecraft instances (P1 top half, P2 bottom half) running correctly in Steam Deck Game Mode (gamescope), each controlled by its own DS4 controller.

---

## Architecture Overview

The launcher (`minecraftSplitscreen.sh`) runs on the Deck and orchestrates everything:

```
minecraftSplitscreen.sh        ← orchestrator, event loop, FIFO
modules/
  controller_monitor.sh        ← detects controller add/remove via udevadm
  dock_detection.sh            ← DRM sysfs: docked (external display) vs handheld
  instance_lifecycle.sh        ← spawn/teardown per-slot bwrap sandboxes
  window_manager.sh            ← compute layout, xdotool window positioning
```

State file: `~/.local/share/PolyMC/splitscreen_state.json`  
Each slot tracks: `active`, `pid`, `bwrap_pid`, `event_node`, `js_node`, `wid`

---

## What Works

- **Dock detection**: correctly identifies docked (external display via DRM sysfs) vs handheld
- **Controller enumeration**: finds Steam virtual Xbox 360 pads (`28de:11ff`) for external controllers, excludes Deck built-in
- **bwrap sandboxes**: each instance launched inside bubblewrap with isolated `/dev` and `/tmp`
- **`qtsingleapp` socket isolation**: `--tmpfs /tmp` prevents PolyMC instances from seeing each other's lock socket
- **PID-based window discovery**: `_poll_for_window` finds the Minecraft window by Java PID (not by title — LWJGL3 ignores the title property)
- **WID stored in state**: after window discovery, WID written to `splitscreen_state.json` so `apply_layout` can use it directly
- **Event-driven layout**: `spawn_instance` → `_poll_for_window` → `apply_layout` (no polling loop)
- **Gamescope anchor window**: a background window that registers with gamescope to keep the session alive

---

## Current Problem: Windows Don't Split

Both instances launch fullscreen and stack on top of each other. P1 is behind P2 (or vice versa). The expected behaviour is P1 top half, P2 bottom half.

### What we know about gamescope windowing

- **`xdotool set_window --name` does not persist** inside gamescope. Windows stay named `"Minecraft* 26.1.2"` regardless of what you set. Confirmed in logs.
- **`xdotool windowmove` / `windowsize`**: called successfully (no errors) but gamescope may not honour the X11 geometry — it composites its own layout onto the KMS output.
- **WID lookup now uses state file first** (commit `8711922`) so we're not relying on name search.
- `apply_layout` IS being called after `_poll_for_window` returns a WID. We just don't know yet if the xdotool geometry commands have any effect inside gamescope's XWayland.

### Root question not yet answered

> Does `xdotool windowmove/windowsize` inside gamescope's XWayland actually affect what's displayed on screen, or does gamescope always stretch the focused window to fill the display?

This needs to be tested directly. The layout loop was removed because it fired before WIDs existed; the event-driven path fires at the right time but we haven't confirmed xdotool geometry takes effect in gamescope.

---

## What Has Been Tried (Controllers — Deferred)

Controller work is deferred while windowing is resolved. Summary for reference:

| Attempt | Result |
|---------|--------|
| `SDL_JOYSTICK_HIDAPI=0` + bind event/js nodes | Worked in some sessions, broke in others depending on which event nodes were selected |
| `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=0` | **Broke everything** — this flag tells SDL to exclude `28de:11ff` devices from ALL backends including evdev, so the only device in the sandbox gets ignored |
| Bind `/dev/hidrawN` + remove `HIDAPI=0` | No hidraw exists for Steam virtual Xbox pads (they're virtual, no physical HID parent) |
| `--bind /dev/null` masking of other controllers | Current remote state. Masks other pads' event/js nodes. Deck built-in still leaks in some cases |

**Current controller state (remote):**
- Controller monitor selects `28de:11ff` Steam virtual Xbox pads — brand-agnostic, works for DS4/Xbox/8BitDo/etc.
- `--bind /dev/null` masks other controllers' event+js nodes inside each sandbox
- No SDL env overrides in bwrap command currently
- **Known issue**: Deck built-in controls P2 instead of DS4; after P2 exits, DS4 maps to P1

---

## Key Files and Their Roles

| File | Purpose | Notes |
|------|---------|-------|
| `minecraftSplitscreen.sh` | Orchestrator, FIFO event loop | Removed polling layout loop (`8711922`) |
| `modules/instance_lifecycle.sh` | bwrap sandbox launch, state management | `_poll_for_window` stores WID in state |
| `modules/window_manager.sh` | Layout computation, xdotool calls | WID-first lookup from state (`8711922`) |
| `modules/controller_monitor.sh` | `28de:11ff` device enumeration + udevadm | `list_eligible_controllers("docked")` |
| `modules/dock_detection.sh` | DRM sysfs connector check | Detects `card0-DP-*` or `card0-HDMI-*` |

---

## Relevant Commits (most recent first)

| Hash | Summary |
|------|---------|
| `4c6c7ef` | Force anchor window size via xdotool; upgrade geometry verification with WARNING logging |
| `dc0983a` | Session log for 2026-06-16 (full debugging history) |
| `b135c8f` | Controller: internal-is-first fallback, 9/9 tests |
| `b48516c` | Eval→temp script for bwrap; nested function fix; xdotool guard; .gitignore; UTF-8 fix |
| `62748f6` | Store WID in state after _poll_for_window; add geometry verification helpers |
| `08ab45d` | Gamescope windowing work log (this file created) |
| `8711922` | WID-first window lookup + remove polling layout loop |
| `ebb57b6` | Merge PR #11 (polymc-appimage-rewrite → gamescope-windowing) |
| `3adf037` | Remove Steam virtual gamepad flag; add docked layout loop (loop now removed) |
| `87aaaae` | `--tmpfs /tmp` for qtsingleapp socket isolation; fix mask conditionals |
| `378b9a5` | Skip placeholder windows for slots beyond grid capacity |
| `656d420` | PID-based window discovery for LWJGL3 + 120s timeout |
| `2b3b1c5` | Gamescope anchor window + controller detection + conditional bwrap js_node |
| `d5f060c` | Docked multi-player controller isolation via bwrap masking |
| `f3b66e7` | Disable SDL3 HIDAPI, force evdev path in bwrap sandbox |
| `c5987da` | Bind event_node into bwrap sandbox |
| `d872abd` | Skip nestedPlasma in pure gamescope (Game Mode launch fix) |
| `0b773d2` | Guard PS1/TERM_PROGRAM in selfUpdate (crash fix) |

---

## Environment Facts

- **SSH**: `deck@steamdeck.home.twoshins.net`
- **Session log**: `~/splitscreen-session.log`
- **PolyMC data**: `~/.local/share/PolyMC/`
- **State file**: `~/.local/share/PolyMC/splitscreen_state.json`
- **Minecraft logs**: `~/.local/share/PolyMC/instances/latestUpdate-{1,2}/.minecraft/logs/latest.log`
- **Display in gamescope**: gamescope creates its own XWayland server; `DISPLAY` inside game processes is set by gamescope
- **Controllers at test time**: 2× DS4 (one `054c:09cc` v2, one `054c:05c4` v1) via Bluetooth → Steam UHID virtual devices
- **Steam virtual Xbox pads**: `event21 js1`, `event25 js3`, `event26 js4` (numbers shift between sessions)

---

## Changes in This Commit

_See individual commit messages in the relevant commits table above._

## Related Documents

| Document | Description |
|----------|-------------|
| `PLAN-WINDOWING-CONTROLLERS.md` | Comprehensive plan with 3-round challenge/refine analysis — windowing (Phase 1), controller isolation (Phase 2), verification (Phase 3) |
| `DECISION-LOG-2026-06-17.md` | Key decisions made during the 3-round challenge process — what was tried, what was ruled out, what we know vs what we assume |
| `SESSION-2026-06-16.md` | Raw full session log from the major debugging session |

## Next Steps

1. **Deploy to Steam Deck** — `git pull` on the Deck, then run in Game Mode with 2 controllers
2. **Check session log** (`~/splitscreen-session.log`) for `[window_manager] Verify slot N:` lines — these show the actual xdotool geometry readback
3. **If xdotool geometry matches expected**: the WID-pipe fix works and the layout should be correct
4. **If xdotool geometry is wrong but returns valid numbers**: gamescope's XWayland reports one geometry but composites differently — see alternatives below
5. **If xdotool geometry returns WARNING**: the `_verify_window_geometry` function will now log clear `WARNING` lines when xdotool fails or geometry doesn't match

---

## Workflow

```bash
# All edits happen locally, then push, then Deck pulls
# Local repo: /Users/scott/Documents/MinecraftSplitscreenSteamdeck/
git add <files> && git commit && git push origin feat/gamescope-windowing

# On Deck:
cd ~/MinecraftSplitscreenSteamdeck && git pull origin feat/gamescope-windowing
```

**Never SCP directly to the Deck** — all changes go through git.
