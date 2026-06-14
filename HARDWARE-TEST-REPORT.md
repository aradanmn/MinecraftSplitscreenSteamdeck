# Hardware Testing Report — June 14, 2026

## Summary

Hardware testing of the Minecraft Splitscreen launcher on Steam Deck OLED (Galileo) running SteamOS. Branch: `claude/elegant-bell-vdupw5`. 14 environment bugs found and fixed. Controller input remains partially unsolved — gamepad works but keyboard/mouse events from the host X11 session contaminate input.

## Environment

- **Device**: Steam Deck OLED (Galileo)
- **OS**: SteamOS 3 with KDE Plasma X11 (Desktop Mode)
- **Launcher**: PolyMC 7.0 (extracted AppImage)
- **Minecraft**: 26.1.2 with Fabric loader 0.19.3
- **Controller mod**: Controlify with splitscreen mod
- **Instances**: latestUpdate-1 through latestUpdate-4 (offline accounts P1-P4)

## Bugs Found and Fixed

| # | Bug | Root Cause | Fix |
|---|-----|-----------|-----|
| 1 | `XDG_SESSION_DESKTOP` unbound | Variable not set in SSH/Desktop sessions | `${VAR:-}` defaults |
| 2 | FIFO deadlock on `exec 9>` | No reader for write-only FIFO open | `exec 9<>` (read-write) |
| 3 | `pkill` exits 1 kills script | `set -e` causes abort on non-zero exit | `\|\| true` on kill calls |
| 4 | FUSE not in bwrap sandbox | AppImage needs FUSE to mount | Extract with `--appimage-extract`, use `squashfs-root/AppRun` |
| 5 | `/tmp` invisible in sandbox | Separate mount on SteamOS | `--dev-bind /tmp /tmp` |
| 6 | `/home` invisible in sandbox | Separate mount on SteamOS | `--dev-bind /home /home` |
| 7 | `/run` invisible, XAUTHORITY missing | Separate mount; SSH sessions lack Xauth | `--dev-bind /run /run` + auto-detect |
| 8 | `/dev/dri` GPU invisible | Separate mount; Minecraft crashes without GPU | `--dev-bind /dev/dri /dev/dri` |
| 9 | `--jvm-args` rejected by PolyMC CLI | PolyMC CLI doesn't support this flag | Set `JvmArgs` in `instance.cfg` + `OverrideJavaArgs=true` |
| 10 | Placeholder windows covering game | `apply_layout` spawned black tkinter windows for inactive slots in fullscreen mode | Skip placeholders when `grid_mode == "full"` |
| 11 | Both controllers assigned to slot 1 | `spawn_instance &` in background; slot 1 looked free | Pre-reserve slots via `update_slot_state` before spawning |
| 12 | `hidePanels` breaks Desktop Mode | `pkill plasmashell` kills KDE session | Only call `hidePanels` in `isSteamDeckGameMode()` |
| 13 | Stale state file on restart | `_ensure_state_file()` only created if missing, never reset | Always reset state file in `main()` startup |
| 14 | `bc` dependency | Used for float division (60/0.5), not installed on Deck | Hardcoded computed values (120, 60) |

## Controller Input Investigation

### Device Topology (Steam Deck in Desktop Mode)

Four Valve/Steam input devices on the system:

| Device | Vendor:Product | Event Node | JS Node | Role |
|--------|---------------|------------|---------|------|
| Valve Software Steam Controller | 28de:1205 | event5 | mouse0 | Physical controller → mouse |
| Valve Software Steam Controller | 28de:1205 | event14 | (kbd) | Physical controller → keyboard |
| steamos-manager | 28de:0000 | event19 | (kbd) | Virtual keyboard from SteamOS manager |
| Microsoft X-Box 360 pad 0 | 28de:11ff | event8 | js0 | Virtual Xbox 360 gamepad |

Steam creates the 28de:11ff virtual device via `/dev/uinput`. The virtual device is HYBRID — `evtest` confirms it has both keyboard keys (KEY_ENTER, KEY_ESC, KEY_A, etc.) AND gamepad buttons (BTN_SOUTH, BTN_EAST, etc.) and analog axes (ABS_X, ABS_Y, ABS_RX, ABS_RY). Capability masks: `key: 7cdb000000000000`, `abs: 3003f`.

### Keyboard Event Path

```
Steam Controller hardware (USB HID)
  → Steam reads /dev/hidraw2
  → Steam Input translates controller buttons to keyboard keycodes
  → /dev/uinput creates /dev/input/event9 (keyboard) on host
  → Xwayland opens event9 via libinput
  → X11 KeyPress events generated
  → X11 socket shared into bwrap via --dev-bind /tmp/.X11-unix
  → Minecraft receives keyboard events via X11 protocol
```

### Approaches Attempted (All Failed to Block Keyboard)

| Approach | Result |
|----------|--------|
| Strip SDL env vars (HIDAPI=0, LINUX_JOYSTICK=1, IGNORE_DEVICES_EXCEPT) | No change |
| Remove event8 from sandbox, bind only js0 | No change |
| Bind hidraw0-2 instead of js0 | Controller works, keyboard still present |
| `xmodmap` set all keycodes to NoSymbol | Failed — GLFW uses raw XKB scancodes, not keysyms |
| `evtest --grab /dev/input/event14` | Killed controller detection entirely |
| Transparent tkinter overlay window | Black screen, no controller, game crashed |
| Steam controller profile set to Gamepad | No change in keyboard contamination |
| `use_enhanced_steam_deck_driver: false` in Controlify | No change |
| `SDL_HIDAPI_LIBUSB_WHITELIST=0` | No change |

### What Works

- Minecraft launches and renders correctly (GPU via /dev/dri)
- Audio works
- Controller is detected by Controlify when using js0 or hidraw
- Gamepad axes and buttons function
- The keyboard/mouse override makes menu navigation difficult but the gamepad keeps working

### Root Cause (Unresolved)

Keyboard/mouse events reach Minecraft through the X11 socket (`--dev-bind /tmp/.X11-unix`). The bwrap sandbox has `/dev/input/` empty (keyboard evdev nodes not visible) but X11 protocol-level keyboard delivery bypasses evdev filtering. Steam Input creates a hybrid virtual device that carries both gamepad and keyboard capabilities. Every attempt to block keyboard at the X11 protocol level has either broken controller detection or the display.

### Potential Solutions (Not Yet Attempted)

1. **Xvfb per-instance** — each instance gets its own headless X server with zero input devices; gamepad through hidraw; requires compositing to real display (Xvfb not installed, needs sudo for `pacman`)
2. **XInput2 device disable** — disable the Steam Controller keyboard XInput2 slave device; requires `xinput` or python-xlib (neither installed, needs sudo)
3. **Separate Wayland compositor** — use Weston or gamescope to create an isolated input environment per instance

## Unit Test Status

50/50 tests pass:
- test_dock_detection.sh: 8/8
- test_controller_monitor.sh: 9/9
- test_window_manager.sh: 9/9
- test_instance_lifecycle.sh: 9/9
- test_watchdog.sh: 7/7
- test_orchestrator.sh: 8/8

## Hardware Test Status

| Stage | Passed | Failed | Skipped | Notes |
|-------|--------|--------|---------|-------|
| Stage 0 (Prerequisites) | 14 | 1 | 1 | bc missing (non-critical); xdotool getactivewindow fails in gamescope |
| Stage 1 (Module Smoke) | 10 | 0 | 0 | All modules working on real hardware |
| Stage 2 (Handheld) | 6-7 | 5-6 | 1-2 | Minecraft launches; controller/keyboard conflict; test prompts removed |
| Stage 3 (Docked) | — | — | — | Not fully tested; both instances launch, controller isolation verified at kernel level |
| Stages 4-6 | — | — | — | Not tested |

## Current Branch State

- **Branch**: `claude/elegant-bell-vdupw5`
- **Bare minimum bwrap**: js_node bind + `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1` only
- **`--native` flag added**: Launches bare PolyMC with no orchestration for controller testing
- **Steam shortcut**: Updated to use `--native` for baseline controller test
