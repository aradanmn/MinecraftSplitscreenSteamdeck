---
name: Game Mode Controller Detection & Isolation
description: How controller detection and per-slot isolation works in gamescope/Game Mode vs Desktop Mode, and the bugs fixed in 2026-03-15 session
type: project
---

## Context
The launcher script (`minecraftSplitscreen.sh`) handles 2 distinct controller environments:
- **Desktop Mode (KDE)**: Raw PS4/physical controllers visible via uhid devices (vendor 054c)
- **Game Mode (gamescope)**: Steam Input grabs raw devices and presents them as "Microsoft X-Box 360 pad" virtual gamepads (vendor 28de) — NOT "Steam Virtual Gamepad" as the old code assumed

## Bugs Fixed (2026-03-15)

### 1. `hasSteamVirtualController()` used wrong name
Old code: `grep -q "Steam Virtual Gamepad" /proc/bus/input/devices`
Fix: check by vendor ID instead — `cat /sys/class/input/jsN/device/id/vendor == "28de"`
**Why:** Steam presents virtual pads as "Microsoft X-Box 360 pad 0/1", not "Steam Virtual Gamepad"

### 2. SDL_JOYSTICK_DEVICE written to instance.cfg didn't reach the JVM
PrismLauncher caches `instance.cfg` in memory after `prewarmLauncher` starts it.
Writing to the file on disk after prewarm has no effect on launched JVMs.
Fix: export `SDL_JOYSTICK_DEVICE` and `SDL_JOYSTICK_HIDAPI=0` directly in the subshell
that runs `flatpak run`, so the env flows: subshell → flatpak → PrismLauncher → Java.
**How to apply:** Always set SDL isolation via process env in the launch subshell, not instance.cfg

### 3. Game Mode used raw device (event11) instead of Steam Virtual Gamepad
In Game Mode, Steam may hold exclusive grab on the raw uhid device.
Fix: In Game Mode (`hasSteamVirtualController()` true), enumerate vendor=28de devices
via `findSteamVirtualEventDevices()` and assign one per slot.
In Desktop Mode, enumerate real (non-28de) devices via `findRealControllerEventDevices()`.

### 4. Merge conflict committed to repo
`launcher_script_generator.sh` had unresolved git conflict markers (`<<<<<<< HEAD` etc.)
committed as-is. Fixed by resolving in favor of the `fe9eec6` side (adds no-terminal guard).

## Controller Slot Assignment Logic
- **First connected = Player 1**: Steam creates virtual devices in connection order;
  `findSteamVirtualEventDevices()` sorted by sysfs path gives connection order.
- **Slots are sticky**: `used_devices` only includes slots where `INSTANCE_ACTIVE[i]=1`.
  Disconnected players' slots are freed; active players keep their assignments.
- **Reconnect to same slot**: `getNextAvailableSlot()` returns lowest free slot.
  The reconnecting controller gets the first unclaimed virtual device.

## Key Functions (in generated minecraftSplitscreen.sh and generator heredoc)
- `hasSteamVirtualController()` — detects Game Mode by vendor 28de
- `findRealControllerEventDevices()` — Desktop Mode: vendor != 28de
- `findSteamVirtualEventDevices()` — Game Mode: vendor == 28de
- `assignControllerToSlot(slot)` — picks correct device, sets INSTANCE_CONTROLLER_DEVICE
- `writeControllableConfigBySerial(slot, dev)` — Desktop: autoSelect=false + GUID; Game Mode: autoSelect=true
- `writeInstanceSdlEnv(slot, dev)` — writes to instance.cfg (backup only; not reliably read by JVM)
- SDL isolation is injected via subshell env in `launchInstanceForSlot()`

## Important: Generator vs Generated Script
The controller isolation functions (`assignControllerToSlot`, `writeControllableConfigBySerial`,
`findRealControllerEventDevices`, etc.) exist ONLY in the generated `minecraftSplitscreen.sh`
heredoc — they were back-ported into `launcher_script_generator.sh` during this session.
Any future reinstall will now include these functions.

## Commits
- `afd63d6` — Game Mode controller detection and per-slot isolation
- `9f3b679` — inject SDL_JOYSTICK_DEVICE via process env, not instance.cfg
