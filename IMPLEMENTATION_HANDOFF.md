# Minecraft Splitscreen Steam Deck — Implementation Handoff

## Who This Document Is For

You are implementing a rewrite of the runtime launcher for a Minecraft splitscreen
system on Steam Deck / SteamOS. Read every section before writing a single line of
code. Each phase has a required test suite; the next phase must not begin until every
test in the current phase passes.

---

## Project Context

The existing codebase (`minecraftSplitscreen.sh` and `modules/`) installs and launches
1–4 Minecraft instances in splitscreen on a Steam Deck or Linux desktop. The installer
(`install-minecraft-splitscreen.sh`) creates four pre-configured PolyMC instances named
`latestUpdate-1` through `latestUpdate-4` under `~/.local/share/PolyMC/instances/`.

The installer is **not changing**. Only the runtime launcher is being rewritten.

### What the existing launcher does (static, to be replaced)

1. Detects how many controllers are connected at startup.
2. Writes `splitscreen.properties` for each active instance.
3. Launches all instances simultaneously with `SDL_JOYSTICK_DEVICE` pinning.
4. Waits for all instances to exit, then restores KDE panels.

### What the new launcher must do (dynamic)

1. Detect whether the Steam Deck is **docked** (external display + external controllers)
   or **handheld** (built-in screen, built-in gamepad only).
2. In **handheld mode**: launch exactly one Minecraft instance using the built-in gamepad.
   No external controllers are used. Static — no dynamic join/leave.
3. In **docked mode**: run an event loop. As external controllers are plugged in or
   unplugged, spawn or tear down Minecraft instances (max 4) and recompute the window
   layout in real time. The built-in Steam Deck gamepad is never used in docked mode.
4. **Controller isolation**: each Minecraft instance must be launched inside a Bubblewrap
   (`bwrap`) sandbox so that only the `/dev/input` nodes for its assigned controller are
   visible. No instance can accidentally read another player's controller.
5. **Layout is horizontal**: see the Layout Specification below.
6. **Slots are sticky**: when a controller disconnects, the remaining instances keep their
   slot numbers and screen positions. No renumbering.

---

## Critical Background: Steam Input on SteamOS

This is required reading. Getting this wrong will cause controller conflicts.

### How Steam Input works on SteamOS

- Steam reads physical controllers via `/dev/hidraw*` (the HID raw interface).
- Steam does **not** issue `EVIOCGRAB` on the evdev device nodes.
- Steam creates **virtual gamepad devices** via `/dev/uinput`. These virtual devices
  have vendor ID `0x28de` (Valve) and product ID `0x11ff`. They appear in
  `/proc/bus/input/devices` as `"Microsoft X-Box 360 pad"` with an empty `Phys=` field.
- Each virtual device gets both an `eventN` and a `jsN` node. The `Handlers=` line in
  `/proc/bus/input/devices` lists both, e.g. `Handlers=event29 js1`.
- **InputPlumber** (`org.shadowblip.InputPlumber` on D-Bus) is a SteamOS system daemon
  (runs as root) that manages the Steam Deck's internal gamepad. It issues `EVIOCGRAB`
  on the physical evdev node for the internal controller and creates its own virtual
  output device. After SteamOS 3.6.2, external controllers are left to Steam Input.
- There is **no kernel-level mapping** from a `28de:11ff` virtual device back to its
  physical source. `Phys=` and `Uniq=` fields are empty for virtual devices.
  Enumeration order is the only reliable signal.
- **Do not** try to grab physical devices with `EVIOCGRAB` — InputPlumber already owns
  them and you will lose that fight.
- **Do not** create your own uinput virtual devices — Steam Input already did this and
  you do not need to duplicate it.
- **Do** use the virtual devices (`28de:11ff`) that Steam and InputPlumber already created.

### Controller isolation via Bubblewrap

The technique used by the PartyDeck project (the closest prior art):

```bash
bwrap \
  --dev-bind / / \
  --dev /dev \
  --dev-bind /dev/input/event3 /dev/input/event3 \
  --dev-bind /dev/input/js0   /dev/input/js0   \
  -- <game command>
```

`--dev /dev` gives the sandbox a clean, empty `/dev`. Then `--dev-bind` selectively
re-adds only the two input nodes that belong to this player. The game cannot open any
other input node — they do not exist inside the sandbox. This is hardware-enforced by
the kernel namespace mechanism, not just an SDL hint.

---

## Repository Layout (files you will create)

All new files live in the same directory as `minecraftSplitscreen.sh`:

```
MinecraftSplitscreenSteamdeck/
├── minecraftSplitscreen.sh          ← REWRITE (Phase 5)
├── modules/
│   ├── dock_detection.sh            ← NEW (Phase 1)
│   ├── controller_monitor.sh        ← NEW (Phase 2)
│   ├── window_manager.sh            ← NEW (Phase 3)
│   └── instance_lifecycle.sh        ← NEW (Phase 4)
└── tests/
    ├── test_dock_detection.sh       ← NEW (Phase 1)
    ├── test_controller_monitor.sh   ← NEW (Phase 2)
    ├── test_window_manager.sh       ← NEW (Phase 3)
    └── test_instance_lifecycle.sh   ← NEW (Phase 4)
```

The `modules/` directory already exists and contains the installer modules — do not
modify any existing file there. The `tests/` directory does not exist; create it.

---

## Layout Specification

This is the exact layout the window manager must produce. It is horizontal-primary
(rows are the primary axis).

```
1 Player:
┌────────────────────────┐
│          P1            │
└────────────────────────┘

2 Players:
┌────────────────────────┐
│          P1            │
├────────────────────────┤
│          P2            │
└────────────────────────┘

3 Players:
┌────────────┬───────────┐
│     P1     │    P2     │
├────────────┼───────────┤
│     P3     │  [BLACK]  │
└────────────┴───────────┘

4 Players:
┌────────────┬───────────┐
│     P1     │    P2     │
├────────────┼───────────┤
│     P3     │    P4     │
└────────────┴───────────┘
```

**[BLACK]** is a plain black borderless window — not a Minecraft instance. It is a
placeholder so the screen is always fully covered. It has no input focus.

### Slot → position mapping

| Slot | 1-player | 2-player | 3-player | 4-player |
|------|----------|----------|----------|----------|
| 1 | full | top half | top-left quad | top-left quad |
| 2 | — | bottom half | top-right quad | top-right quad |
| 3 | — | — | bottom-left quad | bottom-left quad |
| 4 | — | — | [BLACK] bottom-right | bottom-right quad |

### Geometry formulae (W = screen width, H = screen height)

```
full:             x=0,     y=0,     w=W,   h=H
top half:         x=0,     y=0,     w=W,   h=H/2
bottom half:      x=0,     y=H/2,   w=W,   h=H/2
top-left quad:    x=0,     y=0,     w=W/2, h=H/2
top-right quad:   x=W/2,   y=0,     w=W/2, h=H/2
bottom-left quad: x=0,     y=H/2,   w=W/2, h=H/2
bottom-right quad:x=W/2,   y=H/2,   w=W/2, h=H/2
```

All values must be integers (truncate, do not round).

### Grid mode is determined by the highest active slot number

```
highest active slot == 1  →  1-player (full screen)
highest active slot == 2  →  2-player (top/bottom halves)
highest active slot >= 3  →  4-player quad grid
```

This rule means if slots 1 and 3 are active (2 players, but slot 3 is the highest),
the quad grid is used: P1 is top-left, slot 2 position is a black placeholder, P3 is
bottom-left, slot 4 position is a black placeholder.

### Slot persistence

When a controller disconnects:
- The instance in that slot is terminated.
- The vacated slot becomes a black placeholder window.
- No other instance moves or changes geometry.
- No slot is renumbered.
- The grid mode only changes if the highest active slot number changes as a result
  of the disconnect.

### splitscreen.properties values

The Splitscreen Support mod reads a properties file at:
`~/.local/share/PolyMC/instances/latestUpdate-N/.minecraft/config/splitscreen.properties`

Content format:
```
gap=1
mode=<MODE>
```

Mode values to use:

| Grid | Slot | mode value |
|------|------|------------|
| full | 1 | `FULLSCREEN` |
| 2-player | 1 | `TOP` |
| 2-player | 2 | `BOTTOM` |
| quad | 1 | `TOP_LEFT` |
| quad | 2 | `TOP_RIGHT` |
| quad | 3 | `BOTTOM_LEFT` |
| quad | 4 | `BOTTOM_RIGHT` |

---

## State File

All modules share a single JSON state file:
`~/.local/share/PolyMC/splitscreen_state.json`

Schema:
```json
{
  "mode": "docked",
  "slots": {
    "1": {
      "active": true,
      "pid": 12345,
      "event_node": "/dev/input/event3",
      "js_node": "/dev/input/js0",
      "bwrap_pid": 12300
    },
    "2": {
      "active": false,
      "pid": null,
      "event_node": null,
      "js_node": null,
      "bwrap_pid": null
    },
    "3": { "active": false, "pid": null, "event_node": null, "js_node": null, "bwrap_pid": null },
    "4": { "active": false, "pid": null, "event_node": null, "js_node": null, "bwrap_pid": null }
  }
}
```

`pid` is the Java process PID (the actual Minecraft game process).
`bwrap_pid` is the `bwrap` wrapper process PID (parent of the Java process).
`active: false` means the slot has no running instance (vacant or never used).

All writes to this file must be atomic: write to a `.tmp` file first, then `mv` it
into place. Use `jq` for all JSON reads and writes.

---

## IPC: Named Pipe (FIFO)

Modules communicate via a named pipe at:
`~/.local/share/PolyMC/splitscreen.fifo`

Message format (one message per line, fields separated by a single space):
```
CONTROLLER_ADD <event_node> <js_node> <physical_vendor> <physical_product>
CONTROLLER_REMOVE <event_node>
DISPLAY_MODE_CHANGE <handheld|docked>
```

Examples:
```
CONTROLLER_ADD /dev/input/event4 /dev/input/js1 054c 09cc
CONTROLLER_REMOVE /dev/input/event4
DISPLAY_MODE_CHANGE handheld
```

The FIFO is created by the orchestrator at startup and deleted at shutdown.

---

## Phase 1: `modules/dock_detection.sh`

### Purpose

Determine whether the Steam Deck is in handheld mode (built-in screen only) or docked
mode (external display active).

### Environment variable override

If `SPLITSCREEN_MODE` is set to `handheld` or `docked`, skip all detection and return
that value. This is used for testing and for users who want to force a mode.

### Detection logic (in priority order)

**Method 1 — DRM sysfs scan (preferred, no external tools required)**

Scan `/sys/class/drm/` for connector directories. Each connector has a `status` file
containing `connected` or `disconnected`.

The Steam Deck's built-in display connector name matches the pattern `eDP*` or
contains `eDP` (embedded DisplayPort — the internal panel). Any other connector
(HDMI, DP, USB-C DP Alt) is an external output.

Logic:
```
for each /sys/class/drm/card*-*/status:
    read status
    if status == "connected":
        connector_name = dirname basename (the "card0-HDMI-A-1" part)
        if connector_name does NOT match *eDP*:
            → docked
→ handheld (no non-eDP connected output found)
```

**Method 2 — `wlr-randr` fallback (if available)**

Run `wlr-randr 2>/dev/null`. If output contains a display name that is not `eDP*`
with `(current)` or `enabled` status, → docked.

**Method 3 — `kscreen-doctor` fallback (KDE-specific)**

Run `kscreen-doctor -o 2>/dev/null`. If any output other than `eDP*` shows `enabled`,
→ docked.

If all three methods fail to detect an external display, → handheld.

### Public API

All functions must be callable after sourcing the file:
```bash
source modules/dock_detection.sh
```

```bash
# Returns "handheld" or "docked" on stdout. Exit code always 0.
get_display_mode()

# Returns exit code 0 if handheld, 1 if docked.
is_handheld()

# Returns exit code 0 if docked, 1 if handheld.
is_docked()

# Watches for display mode changes. Blocks indefinitely.
# On each change, prints "handheld" or "docked" to stdout and flushes.
# Uses inotifywait on /sys/class/drm/ if available, otherwise polls every 3s.
# Intended to be run in a background subshell.
watch_display_mode()
```

### Logging

All detection steps must write diagnostic lines to stderr (not stdout) prefixed with
`[dock_detection]`. Example:
```
[dock_detection] Checking DRM sysfs connectors...
[dock_detection] Found connected non-eDP connector: card0-HDMI-A-1 → docked
```

### Tests: `tests/test_dock_detection.sh`

The test file must be a standalone executable Bash script. Run it with:
```bash
bash tests/test_dock_detection.sh
```

It must print `PASS` or `FAIL` for each test case and exit 0 only if all pass.

**Test T1.1 — env override handheld**
```bash
SPLITSCREEN_MODE=handheld source modules/dock_detection.sh
result=$(SPLITSCREEN_MODE=handheld get_display_mode)
assert_equals "$result" "handheld" "T1.1"
```

**Test T1.2 — env override docked**
```bash
result=$(SPLITSCREEN_MODE=docked get_display_mode)
assert_equals "$result" "docked" "T1.2"
```

**Test T1.3 — DRM sysfs: only eDP connected → handheld**

Create a temporary directory tree mocking `/sys/class/drm/`:
```
$TMPDIR/sys/class/drm/card0-eDP-1/status  → "connected\n"
$TMPDIR/sys/class/drm/card0-HDMI-A-1/status → "disconnected\n"
```
Override the DRM_PATH variable (the module must support this for testing):
```bash
DRM_PATH="$TMPDIR/sys/class/drm" get_display_mode
```
Expected output: `handheld`

**Test T1.4 — DRM sysfs: HDMI connected → docked**
```
$TMPDIR/sys/class/drm/card0-eDP-1/status  → "connected\n"
$TMPDIR/sys/class/drm/card0-HDMI-A-1/status → "connected\n"
```
Expected output: `docked`

**Test T1.5 — DRM sysfs: no files → handheld**
```
$TMPDIR/sys/class/drm/ is empty
```
Expected output: `handheld`

**Test T1.6 — DRM sysfs: only HDMI connected (no eDP) → docked**
```
$TMPDIR/sys/class/drm/card0-HDMI-A-1/status → "connected\n"
```
Expected output: `docked`

**Test T1.7 — is_handheld() and is_docked() return correct exit codes**
```bash
SPLITSCREEN_MODE=handheld is_handheld;  assert_exit_code 0 "T1.7a"
SPLITSCREEN_MODE=handheld is_docked;   assert_exit_code 1 "T1.7b"
SPLITSCREEN_MODE=docked   is_docked;   assert_exit_code 0 "T1.7c"
SPLITSCREEN_MODE=docked   is_handheld; assert_exit_code 1 "T1.7d"
```

**Test T1.8 — watch_display_mode() emits on change**

Start `watch_display_mode` in background with `DRM_PATH=$TMPDIR/sys/class/drm`.
Initially only eDP connected. After 1s, write `connected` into `card0-HDMI-A-1/status`.
Expect `docked` to appear on stdout within 5s.
Then write `disconnected`. Expect `handheld` within 5s.
Kill background process, assert both events received.

**All 8 tests must pass. No test may require actual Steam Deck hardware.**

---

## Phase 2: `modules/controller_monitor.sh`

### Purpose

Enumerate existing Steam virtual gamepad devices and monitor for controllers being
added or removed. Emit structured messages to the FIFO for the orchestrator to consume.

### What counts as a "controller" in docked mode

A device is eligible in docked mode if ALL of the following are true:
1. It is a Steam virtual gamepad: vendor=`28de`, product=`11ff`.
2. Its physical source device (identified by enumeration — see below) is NOT the
   Steam Deck's built-in gamepad (i.e., not managed by InputPlumber as the internal device).
3. The `28de:11ff` virtual device is not a duplicate of one already assigned.

A device is eligible in handheld mode if:
1. It is the first (lowest-numbered) gamepad-capable device visible, OR
2. `SPLITSCREEN_MODE=handheld` is set and there is at least one input device.
   (Handheld mode always uses exactly one device regardless of what is connected.)

### Identifying the built-in Deck gamepad virtual device in docked mode

**Method 1 — InputPlumber D-Bus query (preferred)**

```bash
busctl call org.shadowblip.InputPlumber \
    /org/shadowblip/InputPlumber \
    org.shadowblip.InputPlumber \
    GetManagedDevices 2>/dev/null
```

This returns a list of object paths for composite devices. For each path, query:
```bash
busctl get-property org.shadowblip.InputPlumber \
    <object_path> \
    org.shadowblip.Input.CompositeDevice \
    SourceDevicePaths 2>/dev/null
```

If any source device path contains `platform` or does not contain `usb` in the sysfs
path, that composite device manages the internal gamepad. Identify the target virtual
device it outputs to, and exclude it from docked-mode assignment.

**Method 2 — Enumeration position fallback**

If InputPlumber D-Bus is not available (not on SteamOS, or service is stopped):
- Enumerate all `28de:11ff` devices in ascending order by their `eventN` number.
- The first one (lowest eventN) is assumed to be the internal gamepad and excluded
  from docked mode.
- This is a heuristic. Log a warning when falling back to this method.

### Parsing /proc/bus/input/devices

To find the `eventN` and `jsN` nodes for a `28de:11ff` device, parse
`/proc/bus/input/devices`. This file contains blocks separated by blank lines.
Each block looks like:

```
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input652
U: Uniq=
H: Handlers=event29 js1
B: ...
```

For each block where `Vendor=28de` AND `Product=11ff`:
- Extract `eventN` from the `Handlers=` line.
- Extract `jsN` from the `Handlers=` line.
- The full paths are `/dev/input/eventN` and `/dev/input/jsN`.

The module must support a `PROC_INPUT_DEVICES` override variable pointing to a file
path instead of `/proc/bus/input/devices`, for use in tests.

### Detecting physical source to identify built-in vs external

For each `28de:11ff` virtual device at `/sys/devices/virtual/input/inputN`:
- Navigate to `/sys/devices/virtual/input/inputN/` and look for a `device` symlink.
  Virtual uinput devices have no real device parent — this symlink may be absent or
  point back to virtual.
- The reliable signal is the order of creation (lowest inputN = created first).
  On a running SteamOS system, InputPlumber starts before Steam, so the internal
  gamepad virtual device will have a lower `inputN` number than external ones.

### Monitoring for changes

Use `udevadm monitor --subsystem-match=input --udev` (not `--kernel`) to receive
events after udev has processed them. Parse stdout lines for `ACTION` (add/remove)
and `DEVPATH` (the sysfs path).

On `add` events: re-enumerate all `28de:11ff` devices, compute the newly appeared
device, determine its event+js nodes, apply docked-mode eligibility filter, and if
eligible write a `CONTROLLER_ADD` message to the FIFO.

On `remove` events: match the departed device's event node against the registry,
write a `CONTROLLER_REMOVE` message to the FIFO.

Debounce: ignore add events for a device that was added within the last 500ms
(prevents duplicate events from USB enumeration).

### Physical vendor/product in CONTROLLER_ADD messages

For the `CONTROLLER_ADD` message, include the physical vendor and product ID of the
source controller. Obtain this by reading:
- The `Vendor=` and `Product=` fields from the physical device's
  `/proc/bus/input/devices` block, OR
- `/sys/class/input/eventN/device/id/vendor` and `.../product` for the physical device.

Since we cannot directly map a `28de:11ff` virtual device to its physical source at
the kernel level, use the enumeration position: the Nth eligible virtual device
(after excluding the internal gamepad) corresponds to the Nth external physical
controller in enumeration order. Read the physical device's vendor/product from its
sysfs path.

### Public API

```bash
source modules/controller_monitor.sh

# Write current eligible virtual device list to stdout.
# Each line: "<event_node> <js_node> <physical_vendor> <physical_product>"
# In docked mode, excludes the internal Deck gamepad.
# In handheld mode, returns exactly one line (the first available device).
list_eligible_controllers()

# Start monitoring. Blocks. Writes CONTROLLER_ADD / CONTROLLER_REMOVE
# messages to the FIFO at SPLITSCREEN_FIFO path.
# Must be run as a background process.
# $1 = mode ("handheld" or "docked")
start_controller_monitor()

# Return the event node and js node for the Nth eligible controller (1-based).
# Output: "<event_node> <js_node>" or empty if not found.
get_controller_by_index() # $1 = index (1-4)
```

### Tests: `tests/test_controller_monitor.sh`

**Test T2.1 — parse_proc_input_devices: single 28de:11ff block**

Create a temp file with one block:
```
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input652
U: Uniq=
H: Handlers=event29 js1

```
Set `PROC_INPUT_DEVICES=<tempfile>`.
Call an internal parsing function `_parse_steam_virtual_devices`.
Expected output: one line `event29 js1`

**Test T2.2 — parse_proc_input_devices: two 28de:11ff blocks**

Two blocks. Expected: two lines, in order of appearance.

**Test T2.3 — parse_proc_input_devices: mixed devices, only 28de:11ff extracted**

Add blocks with vendor=054c (DualSense) and vendor=28de product=0394 (Steam Controller
hardware, not a virtual pad). Only the `28de:11ff` blocks should appear in output.

**Test T2.4 — parse_proc_input_devices: Handlers line with only eventN (no js)**

Some input devices have no joystick handler. Verify the parser handles this gracefully
and does NOT emit a line for it (a device with no jsN is not a gamepad).

**Test T2.5 — list_eligible_controllers in docked mode, no D-Bus (fallback)**

Set `PROC_INPUT_DEVICES` to a file with two `28de:11ff` blocks (event3/js0, event4/js1).
Set `INPUTPLUMBER_DBUS_AVAILABLE=0` to force fallback.
Call `list_eligible_controllers` with mode=docked.
Expected: exactly one line — `event4 js1 ...` (the second device; first is excluded as
internal gamepad under the enumeration heuristic).

**Test T2.6 — list_eligible_controllers in handheld mode**

Same two-block input. Call with mode=handheld.
Expected: exactly one line — `event3 js0 ...` (the first device, the internal gamepad,
which IS used in handheld mode).

**Test T2.7 — list_eligible_controllers: more than 4 eligible devices capped at 4**

Input file with 5 `28de:11ff` blocks (plus 1 excluded as internal).
Docked mode. Expected: exactly 4 lines.

**Test T2.8 — FIFO message format**

Invoke `start_controller_monitor docked` in background with a mock udevadm that
emits a canned add event. Verify the message written to FIFO matches:
`CONTROLLER_ADD /dev/input/event4 /dev/input/js1 054c 09cc`
(exact spacing, forward slashes, lowercase hex vendor/product).

**Test T2.9 — CONTROLLER_REMOVE message on device removal**

Mock udevadm emits a remove event for event4. Verify FIFO receives:
`CONTROLLER_REMOVE /dev/input/event4`

**All 9 tests must pass.**

---

## Phase 3: `modules/window_manager.sh`

### Purpose

Compute window geometry for N active player slots and apply it: reposition/resize
running Minecraft windows and maintain black placeholder windows for vacant slots.

### Screen resolution discovery

Obtain screen dimensions in this priority order:

1. `wlr-randr --output <primary> 2>/dev/null` — parse the current mode line.
2. `kscreen-doctor -o 2>/dev/null` — parse the primary output's current resolution.
3. `xrandr 2>/dev/null` — parse the `*` (current) mode line for the primary output.
4. `xdpyinfo 2>/dev/null` — parse the `dimensions:` line.
5. Environment variable override: `SPLITSCREEN_SCREEN_W` and `SPLITSCREEN_SCREEN_H`.
6. Hardcoded fallback: 1280×800 (Steam Deck native resolution).

### Window identification

Each Minecraft instance is launched with the JVM argument:
`-Dorg.lwjgl.opengl.Window.title=SplitscreenP<N>`

where `<N>` is the slot number (1–4). This sets the X11/Wayland window title.

Use `xdotool search --name "SplitscreenP<N>"` to find the window ID for slot N.
If not found within 30s of the instance being launched, log an error but do not crash.

### Applying window geometry

For each active slot with a known window ID:
```bash
xdotool windowmove <wid> <x> <y>
xdotool windowsize <wid> <w> <h>
```

Also remove window decorations (title bar, borders) by setting the window to
override-redirect or using:
```bash
xdotool set_window --overrideredirect 1 <wid>
```

Raise all game windows above the black placeholder windows:
```bash
xdotool windowraise <wid>
```

### Black placeholder windows

Use `python3 -c` to spawn a minimal Tkinter black window for each vacant slot:
```bash
python3 -c "
import tkinter as tk
import sys
root = tk.Tk()
root.configure(bg='black')
root.overrideredirect(True)
root.geometry('{w}x{h}+{x}+{y}'.format(w=$W, h=$H, x=$X, y=$Y))
root.title('SplitscreenBlack{slot}')
root.mainloop()
" &
```

Track the PID of each placeholder. Kill it when the slot becomes active or when
the layout changes such that the slot no longer needs a placeholder.

If `python3` is not available, fall back to:
```bash
xterm -bg black -fg black -geometry {cols}x{rows}+{x}+{y} -T SplitscreenBlack{slot} &
```
where cols and rows approximate the pixel size in character cells.

### Public API

```bash
source modules/window_manager.sh

# Compute geometry for a given slot in a given grid mode.
# Arguments: $1=slot(1-4), $2=grid_mode(full|half|quad), $3=screen_w, $4=screen_h
# Output: "x y w h" on stdout
compute_slot_geometry()

# Determine grid mode from the set of active slot numbers.
# Arguments: space-separated list of active slot numbers, e.g. "1 3"
# Output: "full", "half", or "quad" on stdout
compute_grid_mode()

# Apply the full layout for the current active slots.
# Arguments: $1=active_slots (space-separated), $2=screen_w, $3=screen_h
# Effects: repositions Minecraft windows, spawns/kills black placeholders
apply_layout()

# Kill all placeholder windows spawned by this module.
kill_all_placeholders()
```

### Tests: `tests/test_window_manager.sh`

These tests cover geometry computation only (no actual windows required).

**Test T3.1 — compute_grid_mode**

| Active slots | Expected mode |
|---|---|
| `"1"` | `full` |
| `"1 2"` | `half` |
| `"2"` | `half` |
| `"1 3"` | `quad` |
| `"1 2 3"` | `quad` |
| `"3"` | `quad` |
| `"4"` | `quad` |
| `"1 2 3 4"` | `quad` |
| `"2 4"` | `quad` |

**Test T3.2 — compute_slot_geometry, full mode, 1920×1080**

Slot 1, full: expect `0 0 1920 1080`

**Test T3.3 — compute_slot_geometry, half mode, 1920×1080**

| Slot | Expected |
|---|---|
| 1 | `0 0 1920 540` |
| 2 | `0 540 1920 540` |

**Test T3.4 — compute_slot_geometry, quad mode, 1920×1080**

| Slot | Expected |
|---|---|
| 1 | `0 0 960 540` |
| 2 | `960 0 960 540` |
| 3 | `0 540 960 540` |
| 4 | `960 540 960 540` |

**Test T3.5 — compute_slot_geometry, quad mode, 1280×800 (Steam Deck)**

| Slot | Expected |
|---|---|
| 1 | `0 0 640 400` |
| 2 | `640 0 640 400` |
| 3 | `0 400 640 400` |
| 4 | `640 400 640 400` |

**Test T3.6 — odd resolution truncates (not rounds)**

Screen: 1366×768

Quad mode:
- Half of 1366 = 683 (truncated, not 683.5 rounded to 684)
- Half of 768 = 384

Slot 4: expected `683 384 683 384`

**Test T3.7 — compute_grid_mode rejects invalid input**

Empty string input → exits non-zero or outputs `full` (document which, but be consistent).

**Test T3.8 — active slots "1 2" switching to "1" triggers grid mode change**

```bash
mode_before=$(compute_grid_mode "1 2")   # → half
mode_after=$(compute_grid_mode "1")      # → full
assert_not_equals "$mode_before" "$mode_after" "T3.8"
```

**Test T3.9 — slot 3 only → quad mode, correct geometry**

Active slots: `"3"` → grid=quad.
`compute_slot_geometry 3 quad 1920 1080` → `0 540 960 540`

**All 9 tests must pass. Tests must not spawn any windows or require a display.**
Use `DISPLAY=` (unset) and verify tests still pass for the geometry-only functions.

---

## Phase 4: `modules/instance_lifecycle.sh`

### Purpose

Spawn and terminate individual Minecraft instances, manage the instance registry
(state file), and coordinate with the window manager.

### Dependencies

This module sources the other three modules:
```bash
source "$(dirname "$0")/dock_detection.sh"
source "$(dirname "$0")/controller_monitor.sh"
source "$(dirname "$0")/window_manager.sh"
```

### Pre-launch steps (per instance)

In this exact order:
1. Write `splitscreen.properties` for this slot's mode (see Layout Specification).
2. Clear `selected_controllers.json` for this instance:
   `rm -f "$LAUNCHER_DIR/instances/latestUpdate-N/.minecraft/config/controllable/selected_controllers.json"`
3. Build the bwrap command (see below).
4. Update the state file to mark slot as active (write `bwrap_pid` after launch).
5. Spawn the instance.
6. Poll for the Java process (up to 60s, 0.5s intervals) using
   `pgrep -af "instances/latestUpdate-N/natives"`.
7. Once Java is detected, record its PID in the state file.
8. Wait for the window to appear (up to 30s) using `xdotool search --name SplitscreenPN`.
9. Call `apply_layout` with all currently active slots.

### bwrap command construction

```bash
bwrap \
  --dev-bind / / \
  --dev /dev \
  --dev-bind "$event_node" "$event_node" \
  --dev-bind "$js_node"    "$js_node"    \
  -- \
  env \
    SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT="0x28DE/0x11FF" \
    SDL_JOYSTICK_DEVICE="$js_node" \
    SDL_JOYSTICK_HIDAPI=0 \
    SDL_LINUX_JOYSTICK_CLASSIC=1 \
    SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=0 \
  "$LAUNCHER_EXEC" \
    -l "latestUpdate-$slot" \
    -a "P$slot" \
    -Dorg.lwjgl.opengl.Window.title="SplitscreenP$slot"
```

Note: `-Dorg.lwjgl.opengl.Window.title` is a JVM argument, not a PolyMC argument.
It must be passed as an additional JVM argument in the instance's `instance.cfg`
(`JvmArgs` key) or via the PolyMC launcher's `--jvm-args` flag if supported.
Check which mechanism PolyMC's AppImage CLI supports and document the finding.

If `bwrap` is not installed, log a clear error and exit 1. Do not attempt to launch
without sandboxing — unsandboxed launch defeats the isolation guarantee.

### Instance teardown

```bash
teardown_instance() {
    local slot="$1"
    # 1. Send SIGTERM to bwrap_pid (this also signals the Java child process).
    # 2. Wait up to 10s for both bwrap_pid and pid to exit.
    # 3. If still alive after 10s, SIGKILL both.
    # 4. Kill the placeholder window for this slot if one exists.
    # 5. Update state file: mark slot inactive, clear pid/bwrap_pid/nodes.
    # 6. Call apply_layout with remaining active slots.
}
```

### State file management

Use `jq` for all reads and writes. Writes must be atomic (tmp file + mv).

```bash
# Read the current state file, return "null" if file doesn't exist
read_state()

# Update a single slot's fields. $1=slot, $2=jq filter expression
update_slot_state()

# Return active slot numbers as a space-separated string, e.g. "1 3"
get_active_slots()

# Return the bwrap PID for a slot
get_bwrap_pid()   # $1=slot

# Return the java PID for a slot
get_java_pid()    # $1=slot
```

### Public API

```bash
source modules/instance_lifecycle.sh

# Spawn a Minecraft instance in the given slot.
# $1=slot (1-4), $2=event_node, $3=js_node
spawn_instance()

# Tear down the instance in the given slot.
# $1=slot
teardown_instance()

# Tear down all active instances.
teardown_all_instances()

# Return 0 if the given slot has an active running instance, 1 otherwise.
# $1=slot
slot_is_active()
```

### Tests: `tests/test_instance_lifecycle.sh`

Tests for this phase may use mocks for the PolyMC launcher and bwrap.

**Test T4.1 — splitscreen.properties written correctly for each slot/grid combination**

For each combination of (slot, active_slots):
- Call the internal `_write_splitscreen_properties slot active_slots` function.
- Read the written file and verify the `mode=` line.

Test matrix (screen to verify is the mode value for that slot):

| Active slots | Grid | Slot 1 | Slot 2 | Slot 3 | Slot 4 |
|---|---|---|---|---|---|
| `1` | full | `FULLSCREEN` | — | — | — |
| `1 2` | half | `TOP` | `BOTTOM` | — | — |
| `1 2 3` | quad | `TOP_LEFT` | `TOP_RIGHT` | `BOTTOM_LEFT` | — |
| `1 2 3 4` | quad | `TOP_LEFT` | `TOP_RIGHT` | `BOTTOM_LEFT` | `BOTTOM_RIGHT` |
| `1 3` | quad | `TOP_LEFT` | — | `BOTTOM_LEFT` | — |
| `2 4` | quad | — | `TOP_RIGHT` | — | `BOTTOM_RIGHT` |

**Test T4.2 — state file atomic write**

Call `update_slot_state 1 '{"active": true, "pid": 999}'`.
Verify the state file is valid JSON after the call.
Verify that no partial write exists (no `.tmp` file left behind).

**Test T4.3 — get_active_slots**

Set up a state file with slots 1 and 3 active, slots 2 and 4 inactive.
Call `get_active_slots`. Expected output: `1 3` (space-separated, ascending order).

**Test T4.4 — slot_is_active**

Same state file.
`slot_is_active 1` → exit 0
`slot_is_active 2` → exit 1
`slot_is_active 3` → exit 0
`slot_is_active 4` → exit 1

**Test T4.5 — teardown_instance marks slot inactive**

Set up state file with slot 2 active, pid=99999 (non-existent process — kill will
fail gracefully). Call `teardown_instance 2`.
Verify state file shows slot 2 as inactive with null pid/bwrap_pid/nodes.

**Test T4.6 — bwrap unavailable → exit 1 with clear message**

Mock `bwrap` as not found:
```bash
PATH=/empty_dir spawn_instance 1 /dev/input/event3 /dev/input/js0
```
Expect exit code 1 and stderr containing the word "bwrap".

**Test T4.7 — spawn_instance writes correct state fields**

Mock bwrap and PolyMC to return immediately with PID 12345.
Call `spawn_instance 2 /dev/input/event4 /dev/input/js1`.
Verify state file slot 2 contains:
- `active: true`
- `event_node: "/dev/input/event4"`
- `js_node: "/dev/input/js1"`
- `bwrap_pid` is a non-null integer

**Test T4.8 — teardown_all_instances clears all slots**

State file with all 4 slots active. Call `teardown_all_instances`.
Verify all 4 slots are inactive. Verify no orphan PIDs remain in state file.

**All 8 tests must pass.**

---

## Phase 5: Orchestrator Rewrite (`minecraftSplitscreen.sh`)

### Scope

Replace the existing main logic of `minecraftSplitscreen.sh` while preserving the
following functions unchanged (they are still needed):
- `detectLauncher()`
- `selfUpdate()`
- `nestedPlasma()`
- `pruneLauncherFrontends()`
- `hidePanels()`
- `restorePanels()`
- `isSteamDeckGameMode()`
- `setInstanceCfgValue()`
- `configureInstanceControllerWrapper()`
- `clearControllableSelection()`

Remove or replace:
- `getControllerCount()` — replaced by controller_monitor.sh
- `getControllerDevices()` — replaced by controller_monitor.sh
- `setSplitscreenModeForPlayer()` — replaced by instance_lifecycle.sh
- `launchGame()` — replaced by instance_lifecycle.sh
- `launchGames()` — replaced by the new event loop

### Source the new modules at the top

```bash
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/modules/dock_detection.sh"
source "$SCRIPT_DIR/modules/controller_monitor.sh"
source "$SCRIPT_DIR/modules/window_manager.sh"
source "$SCRIPT_DIR/modules/instance_lifecycle.sh"
```

### Startup sequence

```
1. detectLauncher() — exit if PolyMC not found
2. selfUpdate() — skip if arg is launchFromPlasma
3. isSteamDeckGameMode():
   YES → if not launchFromPlasma: nestedPlasma() [never returns]
         if launchFromPlasma: continue below
   NO  → continue below
4. Create FIFO: mkfifo "$SPLITSCREEN_FIFO" (if not exists)
5. hidePanels()
6. get_display_mode() → "handheld" or "docked"
7. Branch to handheld_flow() or docked_flow()
```

### handheld_flow()

```
1. list_eligible_controllers handheld → get first device (event_node, js_node)
2. If no device found: log error, exit 1
3. spawn_instance 1 <event_node> <js_node>
4. Wait: while slot_is_active 1; do sleep 2; done
5. teardown_all_instances
6. restorePanels
7. Exit 0
```

### docked_flow()

```
1. Start controller_monitor in background: start_controller_monitor docked &
   Record its PID.
2. Initial scan: list_eligible_controllers docked
   For each device (up to 4), assign to next free slot and spawn_instance.
3. Event loop:
   while read -r line < "$SPLITSCREEN_FIFO"; do
     parse line into ACTION and fields
     case ACTION in
       CONTROLLER_ADD)
         if active_count < 4:
           assign next free slot
           spawn_instance <slot> <event_node> <js_node>
         else:
           log "max 4 players, ignoring new controller"
       CONTROLLER_REMOVE)
         slot = find slot by event_node
         if slot found:
           teardown_instance <slot>
         if get_active_slots is empty:
           log "no players remaining, waiting for controllers..."
       DISPLAY_MODE_CHANGE)
         if new_mode == handheld:
           teardown_all_instances
           kill controller_monitor PID
           handheld_flow   # switch modes live
     esac
   done
4. On exit trap: teardown_all_instances, kill controller_monitor, restorePanels,
   rm -f "$SPLITSCREEN_FIFO"
```

### Environment variables the orchestrator must set/export

```bash
export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
export LAUNCHER_DIR="$HOME/.local/share/PolyMC"
export LAUNCHER_EXEC="$HOME/.local/share/PolyMC/PolyMC.AppImage"
```

### Exit codes

| Situation | Exit code |
|---|---|
| Normal exit (all instances closed) | 0 |
| PolyMC not found | 1 |
| bwrap not found | 1 |
| No controller in handheld mode | 1 |
| Killed by signal | 130 (SIGINT) or 143 (SIGTERM) |

---

## General Requirements (All Phases)

### Shell dialect
All `.sh` files must be `#!/bin/bash`. Bash 4.4+ features are acceptable (SteamOS
ships Bash 5). No `sh`-only syntax.

### Error handling
- Every file starts with `set -euo pipefail` at the top, UNLESS a specific function
  requires disabling it locally (use `set +e` locally with a comment explaining why,
  then re-enable with `set -e`).
- Never silently swallow errors. If a command can fail non-fatally, capture its output
  and log it.

### Logging
- All modules log to stderr with a prefix: `[module_name] message`.
- The orchestrator logs to both stderr and
  `~/.local/share/PolyMC/splitscreen-launch-debug.log` with timestamps.
- Log format: `[YYYY-MM-DD HH:MM:SS] [module] message`

### jq dependency
`jq` must be present. Check at startup:
```bash
command -v jq >/dev/null 2>&1 || { echo "[Error] jq is required but not installed." >&2; exit 1; }
```

### bwrap dependency
Check at startup (before any instance is spawned):
```bash
command -v bwrap >/dev/null 2>&1 || { echo "[Error] bwrap (bubblewrap) is required." >&2; exit 1; }
```

### No global state mutation in modules
Module files must not execute any code when sourced — only define functions.
Any variable they set must be prefixed with the module name, e.g.
`DOCK_DETECTION_DRM_PATH`, `CONTROLLER_MONITOR_FIFO`, etc.

### Test harness requirements
Every test file must:
1. Be executable: `chmod +x tests/test_*.sh`
2. Source modules using paths relative to the repo root.
3. Use a temp directory (`mktemp -d`) for all file I/O; clean it up on exit via trap.
4. Print `[PASS] T1.1 — description` or `[FAIL] T1.1 — description` for each test.
5. Print a summary: `X/Y tests passed.`
6. Exit 0 if all pass, exit 1 if any fail.
7. Not require root, not require hardware, not require a running Steam instance.

---

## Deliverable Checklist

Phase 1 complete when:
- [ ] `modules/dock_detection.sh` exists and is non-empty
- [ ] `tests/test_dock_detection.sh` exits 0 with output `8/8 tests passed.`

Phase 2 complete when:
- [ ] `modules/controller_monitor.sh` exists and is non-empty
- [ ] `tests/test_controller_monitor.sh` exits 0 with output `9/9 tests passed.`

Phase 3 complete when:
- [ ] `modules/window_manager.sh` exists and is non-empty
- [ ] `tests/test_window_manager.sh` exits 0 with output `9/9 tests passed.`

Phase 4 complete when:
- [ ] `modules/instance_lifecycle.sh` exists and is non-empty
- [ ] `tests/test_instance_lifecycle.sh` exits 0 with output `8/8 tests passed.`

Phase 5 complete when:
- [ ] `minecraftSplitscreen.sh` has been updated
- [ ] All four previous test suites still pass
- [ ] `bash -n minecraftSplitscreen.sh` exits 0 (syntax check)
- [ ] `bash -n modules/dock_detection.sh` exits 0
- [ ] `bash -n modules/controller_monitor.sh` exits 0
- [ ] `bash -n modules/window_manager.sh` exits 0
- [ ] `bash -n modules/instance_lifecycle.sh` exits 0

**Final gate**: Run all four test suites in sequence. Total must be 34/34 tests passed.
```bash
bash tests/test_dock_detection.sh && \
bash tests/test_controller_monitor.sh && \
bash tests/test_window_manager.sh && \
bash tests/test_instance_lifecycle.sh
```

---

## What NOT to Change

- `install-minecraft-splitscreen.sh`
- `add-to-steam.py`
- `uninstall-minecraft-splitscreen.sh`
- `accounts.json`
- Any file under `modules/` that already exists (java_management.sh,
  launcher_setup.sh, version_management.sh, lwjgl_management.sh,
  mod_management.sh, instance_creation.sh, steam_integration.sh,
  desktop_launcher.sh, main_workflow.sh, utilities.sh)
- `.github/` directory

---

## Style Guide

Every file produced for this project must follow these rules without exception.
Reviewers will reject code that violates them regardless of whether it works correctly.

---

### Bash Style

#### Shebang and shell options
Every `.sh` file must begin with exactly these two lines, with no blank line between
them:
```bash
#!/bin/bash
set -euo pipefail
```

When a specific block must tolerate failures, disable locally and re-enable immediately:
```bash
set +e
some_command_that_may_fail
set -e
```
Never disable `set -u` (undefined variable detection) or `set -o pipefail` locally.

#### No magic numbers
Every numeric literal that represents a threshold, limit, timeout, or configuration
value must be assigned to a named constant at the top of the file in which it is used.
Naming convention: `SCREAMING_SNAKE_CASE` prefixed with the module name.

**Wrong:**
```bash
[ "$count" -gt 4 ] && count=4
sleep 0.5
for _i in $(seq 1 120); do
```

**Right:**
```bash
readonly MAX_PLAYERS=4
readonly LAUNCH_POLL_INTERVAL_S=0.5
readonly LAUNCH_POLL_TIMEOUT_ITERATIONS=120   # 60s total at 0.5s intervals

[ "$count" -gt "$MAX_PLAYERS" ] && count=$MAX_PLAYERS
sleep "$LAUNCH_POLL_INTERVAL_S"
for _i in $(seq 1 "$LAUNCH_POLL_TIMEOUT_ITERATIONS"); do
```

Required named constants (define these in `instance_lifecycle.sh`):
```bash
readonly MAX_PLAYERS=4
readonly LAUNCH_POLL_INTERVAL_S=0.5
readonly LAUNCH_POLL_TIMEOUT_S=60
readonly WINDOW_WAIT_TIMEOUT_S=30
readonly TEARDOWN_GRACE_S=10
readonly CONTROLLER_DEBOUNCE_MS=500
readonly DOCK_POLL_INTERVAL_S=3
readonly DEFAULT_SCREEN_W=1280
readonly DEFAULT_SCREEN_H=800
```

#### Naming conventions
| Thing | Convention | Example |
|---|---|---|
| Functions | `snake_case` | `get_display_mode` |
| Local variables | `snake_case` | `local event_node` |
| Module-level constants | `MODULE_SCREAMING_SNAKE` | `DOCK_DETECTION_DRM_PATH` |
| Loop counters / throwaway | `_name` prefix | `local _i` |
| Boolean-intent variables | name as a predicate | `local is_docked=0` |

Function names must be verbs or verb phrases: `get_`, `set_`, `is_`, `has_`,
`compute_`, `apply_`, `spawn_`, `teardown_`, `list_`, `watch_`, `start_`, `kill_`.
Internal/private functions (not part of a module's public API) must be prefixed
with `_`: `_parse_steam_virtual_devices`, `_write_splitscreen_properties`.

#### Variable quoting
Always double-quote variable expansions unless you specifically need word-splitting:
```bash
# Wrong
cp $src $dest
[ $count -gt 0 ]

# Right
cp "$src" "$dest"
[ "$count" -gt 0 ]
```

Arrays must use `"${array[@]}"` (with quotes) in all expansions:
```bash
# Wrong
for item in ${array[*]}; do

# Right
for item in "${array[@]}"; do
```

#### Local variables
Every variable inside a function must be declared `local`. No function may set or
modify global/module-level variables except through an explicit `export` statement
that is documented in the function's header comment.

```bash
# Wrong
my_function() {
    result="something"   # leaks into global scope
}

# Right
my_function() {
    local result="something"
}
```

#### Function header comments
Every public function (those in the module's public API section) must have a header
comment block immediately above the `function_name()` line:
```bash
# Brief one-line description of what this function does.
# Arguments:
#   $1  slot       — integer 1-4
#   $2  event_node — full path, e.g. /dev/input/event3
# Outputs:
#   stdout: nothing
#   stderr: progress log lines
# Returns:
#   0 on success
#   1 if bwrap is not installed
#   2 if the slot is already active
spawn_instance() {
```

Internal (`_`-prefixed) functions do not require header comments unless the logic
is non-obvious.

#### Command substitution
Use `$(...)` not backticks:
```bash
# Wrong
result=`some_command`

# Right
result=$(some_command)
```

#### Conditionals
Use `[[ ]]` for string/file tests, `(( ))` for arithmetic:
```bash
# Wrong
if [ "$mode" = "docked" ]; then
if [ $count -gt 0 ]; then

# Right
if [[ "$mode" == "docked" ]]; then
if (( count > 0 )); then
```

#### Process substitution for arrays
Use `mapfile` / `readarray` for populating arrays from command output:
```bash
# Wrong
devices=$(ls /dev/input/js*)

# Right
mapfile -t devices < <(ls /dev/input/js* 2>/dev/null)
```

#### Error messages
All error messages must go to stderr and include the function name:
```bash
echo "[spawn_instance] ERROR: bwrap not found. Cannot sandbox instance." >&2
```

Use `return 1` (not `exit 1`) from functions, so the caller can decide whether
the error is fatal.

#### No `cd` inside functions
Functions must never `cd` without saving and restoring the original directory.
Prefer constructing absolute paths instead:
```bash
# Wrong
cd "$target_dir"
some_command file.txt

# Right
some_command "$target_dir/file.txt"
```

#### Pipelines and error checking
Never discard pipeline failures silently. When using pipelines in conditions,
rely on `set -o pipefail` (already required). When capturing pipeline output,
use a temp variable and check it:
```bash
# Wrong
result=$(cat file | grep pattern | head -1)

# Right
result=$(grep pattern file 2>/dev/null | head -1) || true
```

---

### Python Style (controller_proxy.py if needed in future)

If any Python files are added, they must:
- Target Python 3.8+ (SteamOS ships Python 3.10+)
- Use type hints on all function signatures
- Follow PEP 8 (4-space indent, max 100 chars per line)
- Have no magic numbers — use `SCREAMING_SNAKE_CASE` module-level constants
- Have no `print()` for logging — use `logging.getLogger(__name__)`

---

### Repository References

The canonical repository URL for this project is:
```
https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
```

The raw content base URL is:
```
https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/
```

**Never hardcode the FlyingEwok GitHub username in any new or modified file.**
The `install-jdk-on-steam-deck` dependency at
`https://github.com/FlyingEwok/install-jdk-on-steam-deck` is the only exception —
it is an external dependency, not this project.

---

### Commit Message Style

Format:
```
<type>(<scope>): <short summary in imperative mood, ≤72 chars>

<body: explain WHY, not what — optional if summary is self-explanatory>
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`
Scopes: `dock-detection`, `controller-monitor`, `window-manager`, `instance-lifecycle`,
`orchestrator`, `tests`, `readme`

Examples:
```
feat(dock-detection): add DRM sysfs fallback when wlr-randr unavailable

fix(controller-monitor): debounce rapid plug/unplug within 500ms window

test(window-manager): add T3.6 for odd-resolution truncation behaviour
```

---

### What Never Belongs in Code

- Commented-out code blocks — delete dead code, use git history to recover it
- `TODO` comments — open a GitHub issue instead
- Inline explanations of what the code does — rename the variable/function instead
- Author names or dates in comments — git blame has this
- Logging of sensitive paths or environment variables that could expose user data

---

## Key Constraints Summary

1. Maximum 4 simultaneous Minecraft instances.
2. In handheld mode: exactly 1 instance, built-in Steam Deck gamepad only.
3. In docked mode: 0–4 instances, external controllers only, built-in gamepad excluded.
4. Every instance MUST be launched inside a `bwrap` sandbox. No exceptions.
5. Slots are sticky: a slot number, once assigned, is not reassigned until the
   orchestrator restarts. A slot freed by a disconnect can be reused by the NEXT
   controller that connects.
6. Layout mode is determined by the highest active slot number, not the count of
   active players.
7. Vacant slots in quad or half-grid mode show a black borderless placeholder window.
8. All JSON state writes must be atomic (tmp + mv).
9. All module files must be sourceable without side effects.
10. All tests must pass without hardware, root, or a running Steam client.
