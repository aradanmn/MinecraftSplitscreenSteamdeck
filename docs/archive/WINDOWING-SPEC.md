# Minecraft Splitscreen Steam Deck — Definitive Windowing Specification
## After 4 Challenge/Refine Cycles — Codable Implementation Plan

---

## EXECUTIVE SUMMARY

| Mode | Approach | Mechanism | Window Tool | Complexity |
|------|----------|-----------|-------------|------------|
| **Game Mode** (gamescope) | Single window compositor — use nested Xwayland inside kwin_wayland | `kwin_wayland --xwayland` as a Wayland client of wlserver | `dex` (ctypes-based X11 via bundled Python) | HIGH |
| **Desktop Mode** (KWin) | Native KWin window management | N/A — KWin already manages windows | `dex` | LOW |
| **Both** | `dex` replaces xdotool (not available on SteamOS) | python3 + ctypes + libX11.so.6 | `modules/dex.sh` | MEDIUM |

---

## PROBLEM STATEMENT (verified against actual system)

1. **xdotool is NOT installed** (`pacman -Q xdotool` fails, not in PATH)
2. **tkinter is NOT available** (`libtk8.6.so` missing — placeholder window approach broken)
3. **Xephyr is NOT installed**
4. **Xwayland IS available** (`/usr/sbin/Xwayland`)
5. **kwin_wayland IS available** (`/usr/sbin/kwin_wayland`)
6. **PyQt6 IS available** (for KWin scripting if needed)
7. **GTK (gi) IS available** (anchor window current approach)
8. **gamescope is the compositor in Game Mode** — single-window, only composites one focused game window as base layer
9. **gamescope forces the focused game window to fullscreen** — `XResizeWindow(focus, fs_width, fs_height)` on every focus event

---

## CYCLE 1: Game Mode — Pure gamescope approach (REJECTED)

**Proposal:** Two Minecraft windows inside gamescope, one as base layer, second as override-redirect window.

**Challenges identified:**
1. `GAMESCOPECTRL_BASELAYER_WINDOW` pins ONE window as base layer
2. Non-focused windows with override_redirect DO get rendered, but NOT as full-fidelity game windows — they're composited in the override plane with their own geometry
3. gamescope's `force_windows_fullscreen` flag (controlled by root window property `GAMESCOPE_FORCE_WINDOW_FULLSCREEN`) will resize the focused window to fullscreen on every focus event
4. The second window would not receive proper GPU rendering priority — LWJGL3/OpenGL context for the non-focused window may not get swapped in
5. Steam Input will only inject virtual gamepad to ONE focused window

**VERDICT: REJECTED.** Cannot get two independent game windows composited side-by-side in gamescope at full GPU performance.

---

## CYCLE 2: Desktop Mode — KWin native approach (ACCEPTED)

**Proposal:** Use KWin's native window management in Desktop Mode. Replace xdotool with `dex` (Python ctypes X11 wrapper).

**Challenges identified:**
1. **xdotool not available** — solved by `modules/dex.sh`
2. **tkinter not available** — placeholders must use GTK instead 
3. **KWin decorations interfere** — solved by `dex_set_override_redirect` + `dex_set_skip_taskbar`

**Refined implementation:**
- Detect Desktop Mode via `XDG_SESSION_DESKTOP != gamescope`
- Source `modules/dex.sh` instead of relying on xdotool
- Use GTK-based black placeholder windows instead of tkinter
- All existing `apply_layout()`, `compute_grid_mode()`, `compute_slot_geometry()` unchanged
- Only the window manipulation calls need porting from xdotool → dex

**Placeholder window replacement (tkinter → GTK):**
```bash
python3 -c "
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk
win = Gtk.Window()
win.set_decorated(False)
win.set_default_size(W, H)
win.move(X, Y)
win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0, 0, 0, 1))
win.set_title('SplitscreenBlack{slot}')
win.show_all()
Gtk.main()
"
```

**VERDICT: ACCEPTED.** Desktop Mode works with `apply_layout()` + `dex` replacement. The existing integration test (T6.8) must be updated to mock dex instead of xdotool.

---

## CYCLE 3: Game Mode — Nested KWin approach (ACCEPTED with caveats)

**Proposal:** Launch `kwin_wayland --xwayland` inside gamescope's compositor, giving each Minecraft instance a proper X11 window manager.

**Architecture:**
```
┌────────────────────────────────────────────────┐
│ gamescope (wlserver Wayland compositor)         │
│  ┌──────────────────────────────────────────┐   │
│  │ kwin_wayland (nested, Wayland client)     │   │
│  │  ┌────────────────────────────────────┐  │   │
│  │  │ Xwayland (:1, rootless, inside KWin)│  │   │
│  │  │  ┌──────────┬──────────┐          │  │   │
│  │  │  │ P1 (top) │ P2 (bot) │          │  │   │
│  │  │  ├──────────┼──────────┤          │  │   │
│  │  │  │ P3 (left)│ P4 (right)│          │  │   │
│  │  │  └──────────┴──────────┘          │  │   │
│  │  └────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────┘   │
│                     ↕ KWin window = gamescope's  │
│                       single composited surface  │
└────────────────────────────────────────────────┘
```

**Key insight from the challenge:** gamescope's wlserver is the Wayland compositor. `kwin_wayland` runs as a Wayland client of it. The single KWin window is gamescope's focused game window. Inside KWin, Xwayland provides a full X11 WM where `dex` positioning works normally.

**Challenges remaining:**
1. **Wayland socket discovery:** Inside gamescope, we need `WAYLAND_DISPLAY=wayland-0`. But we must verify this works outside Steam's wrapper. When Steam launches a game, it may not set `WAYLAND_DISPLAY` — gamescope itself does. Check `/proc/$(pgrep -x gamescope)/environ`.
2. **kwin_wayland crash issues:** If kwin_wayland crashes, all instances are lost. The watchdog module must handle this.
3. **Input handling across nested compositors:** Steam Input virtual gamepads (28de:11ff) talk to Minecraft via SDL inside the bwrap sandbox. This should work transparently since bwrap gives direct /dev/input access regardless of the display server.
4. **Performance:** The nested compositor adds latency. For the Steam Deck's 800p display with Minecraft, this should be acceptable (Minecraft isn't a fast-twitch FPS).

**Revised startup sequence (codable):**

```bash
launch_nested_kwin() {
    local W=1280 H=800
    local res
    res=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2}')
    [[ -n "$res" ]] && W="${res%%x*}" && H="${res##*x}"
    
    # Discover Wayland socket — gamescope sets it in its process env
    local wl_socket="wayland-0"
    local gamescope_pid
    gamescope_pid=$(pgrep -x gamescope 2>/dev/null | head -1)
    if [[ -n "$gamescope_pid" ]]; then
        local env_wl
        env_wl=$(tr '\0' '\n' < "/proc/$gamescope_pid/environ" 2>/dev/null | grep '^WAYLAND_DISPLAY=' | cut -d= -f2 || true)
        [[ -n "$env_wl" ]] && wl_socket="$env_wl"
    fi
    
    echo "[window_manager] Launching nested KWin on WAYLAND_DISPLAY=$wl_socket" >&2
    
    # Launch kwin_wayland as a Wayland client of gamescope
    WAYLAND_DISPLAY="$wl_socket" \
    kwin_wayland \
        --xwayland \
        --width "$W" \
        --height "$H" \
        --no-lockscreen \
        --exit-with-session "/bin/bash -c 'sleep infinity'" &
    
    local kwin_pid=$!
    echo "[window_manager] KWin PID: $kwin_pid" >&2
    
    # Wait for KWin's Xwayland display to come up
    local max_wait=10
    local xdisplay=""
    for ((i=0; i<max_wait; i++)); do
        # KWin's Xwayland usually uses :1
        if xdpyinfo -display :1 >/dev/null 2>&1; then
            xdisplay=":1"
            break
        fi
        sleep 1
    done
    
    if [[ -z "$xdisplay" ]]; then
        echo "[window_manager] ERROR: KWin Xwayland did not start" >&2
        return 1
    fi
    
    echo "[window_manager] KWin Xwayland ready on display $xdisplay" >&2
    export DEX_DISPLAY="$xdisplay"
    export DISPLAY="$xdisplay"
    export _KWin_PID="$kwin_pid"
}
```

**VERDICT: ACCEPTED.** This is the only viable approach for Game Mode that works with zero new packages. The nested KWin provides a proper X11 WM for Minecraft instances.

---

## CYCLE 4: Edge Cases and Integration Details

### Controller isolation across compositors

The bwrap sandbox gives each Minecraft instance direct `/dev/input/eventN` and `/dev/input/jsN` access. This works regardless of whether the display server is gamescope (direct), KWin (Desktop Mode), or nested KWin (Game Mode). No changes needed to `instance_lifecycle.sh` or `_build_bwrap_command()`.

### Steam Input in Desktop Mode

**Challenge:** In Desktop Mode, Steam may not be running with virtual gamepad creation (28de:11ff). The controllers may appear as raw HID devices (054c:09cc, 054c:05c4) instead of Steam virtual pads.

**Solution:** The `controller_monitor.sh` module already handles this — `list_eligible_controllers docked` finds 28de:11ff devices if they exist, and falls back to any jsN-capable device. The bwrap sandbox binds the actual device nodes regardless of VID:PID.

**BUT** in Desktop Mode without Steam Input, each Minecraft instance gets ALL controllers (no 28de:11ff virtual pads). The controller isolation via bwrap's `--bind /dev/null` masking still works at the evdev level — each sandbox only sees its assigned device.

### Steam gamepad creation in Desktop Mode

**Challenge:** When launched from Desktop Mode (not through Steam), there are no 28de:11ff virtual gamepads. The physical DS4/DualSense controllers are used directly.

**Solution:** 
- In Game Mode (via Steam): Steam creates 28de:11ff virtual pads → `controller_monitor.sh` finds them → bwrap isolation works
- In Desktop Mode (standalone): Physical controllers appear as raw 054c:09cc/054c:05c4 → `controller_monitor.sh` still finds them (handheld mode accepts any gamepad, docked mode needs update)

**Modification needed in `controller_monitor.sh`:** In docked mode, if no 28de:11ff devices are found, fall back to enumerating ALL gamepad-capable devices (any with jsN handler).

### Game Mode → Desktop Mode transitions

The `isSteamDeckGameMode()` function detects the mode. The planned flow:

```bash
if isSteamDeckGameMode; then
    # In Game Mode
    if [[ "$display_mode" == "docked" ]]; then
        launch_nested_kwin   # Start KWin inside gamescope
        # Now DEX_DISPLAY points to KWin's Xwayland
    fi
    # Continue with normal docked_flow/handheld_flow
fi
```

### Placeholder windows without tkinter

Replace `_spawn_placeholder()` in `window_manager.sh`:

Old (tkinter, broken):
```python
import tkinter as tk
root = tk.Tk()
root.configure(bg='black')
root.overrideredirect(True)
root.geometry('${w}x${h}+${x}+${y}')
root.title('SplitscreenBlack${slot}')
root.mainloop()
```

New (GTK, works):
```python
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk
win = Gtk.Window()
win.set_decorated(False)
win.set_default_size(${w}, ${h})
win.move(${x}, ${y})
win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0, 0, 0, 1))
win.set_title('SplitscreenBlack${slot}')
win.show_all()
Gtk.main()
```

---

## EXACT CODE CHANGES REQUIRED

### File 1: `modules/dex.sh` — NEW FILE (created above)

Replace xdotool with ctypes-based X11 manipulation. Functions map 1:1:
- `xdotool search --name <pattern>` → `dex_search --name <pattern>`
- `xdotool search --pid <pid>` → `dex_search --pid <pid>`
- `xdotool getwindowgeometry <wid>` → `dex_getgeometry <wid>`
- `xdotool windowmove <wid> <x> <y>` → `dex_move <wid> <x> <y>`
- `xdotool windowsize <wid> <w> <h>` → `dex_resize <wid> <w> <h>`
- `xdotool windowraise <wid>` → `dex_raise <wid>`
- `xdotool set_window --name <name> <wid>` → `dex_set_name <wid> <name>`
- `xdotool set_window --overrideredirect 1 <wid>` → `dex_set_override_redirect <wid> 1`
- `xprop -root -f GAMESCOPECTRL_BASELAYER_WINDOW 32c -set ...` → `dex_set_root_atom GAMESCOPECTRL_BASELAYER_WINDOW <value>`

### File 2: `modules/window_manager.sh` — MODIFY

Replace all `xdotool` calls with `dex_*` equivalents:

| Current Line | Replace With |
|---|---|
| `xdotool search --name "SplitscreenP${slot}"` → | `dex_search --name "SplitscreenP${slot}"` |
| `xdotool search --pid "$java_pid"` → | `dex_search --pid "$java_pid"` |
| `xdotool windowmove "$wid" "$x" "$y"` → | `dex_move "$wid" "$x" "$y"` |
| `xdotool windowsize "$wid" "$w" "$h"` → | `dex_resize "$wid" "$w" "$h"` |
| `xdotool set_window --overrideredirect 1 "$wid"` → | `dex_set_override_redirect "$wid" 1` |
| `xdotool windowraise "$wid"` → | `dex_raise "$wid"` |
| `xdotool set_window --name "SplitscreenP${slot}" "$wid"` → | `dex_set_name "$wid" "SplitscreenP${slot}"` |
| `xdotool getwindowgeometry "$wid"` → | `dex_getgeometry "$wid"` |

Replace python3 tkinter placeholder with GTK placeholder in `_spawn_placeholder()`.

### File 3: `modules/instance_lifecycle.sh` — MODIFY

In `_poll_for_window()`: replace `xdotool search --name` and `xdotool search --pid` with `dex_search`.

In `_build_bwrap_command()`: ensure `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1` etc. are set (already done).

### File 4: `minecraftSplitscreen.sh` — MODIFY

In `launch_gamescope_anchor()`: replace `xdotool search --pid` with `dex_search --pid`, replace `xdotool windowmove/windowsize/set_window` with `dex_move/dex_resize/dex_set_override_redirect`.

Add `launch_nested_kwin()` function for Game Mode docked mode.

Modify MAIN:
```bash
# After display_mode detection, before branching to handheld_flow/docked_flow:
if isSteamDeckGameMode && [[ "$display_mode" == "docked" ]]; then
    launch_nested_kwin  # Sets DEX_DISPLAY to KWin's Xwayland (:1)
    # Also update anchor window to use the nested display
fi
```

### File 5: `modules/controller_monitor.sh` — MODIFY

In docked mode, if no 28de:11ff devices found, fall back to any gamepad-capable device (any jsN handler).

### File 6: `tests/test_window_manager.sh` — MODIFY

Replace xdotool-based geometry tests with dex-based tests.
Add test for dex functionality (dex_search, dex_move, dex_resize).
Remove/replace tests that depend on xdotool binary.

### File 7: `tests/gamescope-xdotool-test.sh` — REWRITE as `tests/gamescope-dex-test.sh`

Replace all xdotool calls with dex equivalents.
Test creates two GTK windows (not tkinter — tkinter is broken).
Tests move/resize using dex.

---

## IMPLEMENTATION ORDER

### Phase 1: `modules/dex.sh` (foundation)
1. Create `modules/dex.sh` with all dex_* functions (DONE — file created above)
2. Test: `source modules/dex.sh && dex_get_root_wid && dex_list_windows`
3. Test: create a test window and move/resize it with dex

### Phase 2: Update `modules/window_manager.sh`
1. Replace xdotool → dex in `apply_layout()`
2. Replace tkinter placeholder → GTK placeholder in `_spawn_placeholder()`
3. Replace xdotool geometry verification → dex in `_verify_window_geometry()`
4. Replace xdotool search → dex in `_get_wid_from_state()`
5. Source `modules/dex.sh` at top of window_manager.sh

### Phase 3: Update `modules/instance_lifecycle.sh`
1. Replace xdotool search → dex in `_poll_for_window()`
2. Source `modules/dex.sh` at top (or rely on orchestrator sourcing)

### Phase 4: Update `minecraftSplitscreen.sh`
1. Source `modules/dex.sh`
2. Replace xdotool → dex in `launch_gamescope_anchor()`
3. Add `launch_nested_kwin()` function
4. Add nested KWin launch logic in MAIN for Game Mode + docked
5. Update anchor window display for nested mode

### Phase 5: Update `modules/controller_monitor.sh`
1. Add fallback for non-28de:11ff devices in docked mode

### Phase 6: Update test files
1. Convert `tests/gamescope-xdotool-test.sh` → `tests/gamescope-dex-test.sh`
2. Update `tests/test_window_manager.sh`
3. Update `tests/test_instance_lifecycle.sh`
4. Update hardware test suite references

---

## MODE DETECTION LOGIC (exact code)

```bash
# In minecraftSplitscreen.sh main(), after display_mode detection:

# Check if we're in Game Mode (gamescope) and docked (multi-player)
if isSteamDeckGameMode; then
    if [[ "$display_mode" == "docked" ]] && [[ "$(get_active_slots | wc -w)" -ge 2 ]]; then
        # Game Mode + docked + multi-player → launch nested KWin
        launch_nested_kwin
    fi
fi

# Source dex for window management
source "$SCRIPT_DIR/modules/dex.sh"
```

---

## RISK ASSESSMENT

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| kwin_wayland fails to start as Wayland client | Game Mode splitscreen broken | Medium | Fall back to single-instance mode with GAMESCOPECTRL_BASELAYER_WINDOW |
| WAYLAND_DISPLAY not set in gamescope session | Nested KWin cannot connect | Medium | Discover via `/proc/gamescope_pid/environ` or try common sockets |
| KWin Xwayland display number not :1 | dex targets wrong display | Medium | Poll `xdpyinfo -display :N` for N in 0-5 |
| Nested compositor performance impact | Low FPS in splitscreen | Low | Minecraft is CPU-bound at 800p, compositing overhead is minimal |
| No 28de:11ff devices in Desktop Mode | Controller isolation fails | Medium | Fall back to raw evdev isolation (already supported by bwrap) |
| GTK main loop blocks in placeholder | Placeholder windows hang | Low | Run with `&` and track PID (same as tkinter approach) |

---

## TEST PLAN

### Unit tests (no hardware needed)
1. `dex_search --name <pattern>` — find windows by title substring
2. `dex_search --pid <pid>` — find windows by process ID
3. `dex_move_resize <wid> <x> <y> <w> <h>` — move and resize
4. `dex_getgeometry <wid>` — read back geometry
5. `dex_set_override_redirect` — toggle override-redirect
6. `dex_set_root_atom` — set root window property
7. `dex_find_minecraft_windows` — find SplitscreenP{N} windows

### Integration tests (no hardware needed)
1. `apply_layout()` with dex instead of xdotool — verify geometry computation
2. `_spawn_placeholder()` with GTK — verify black window appears
3. `launch_nested_kwin()` — verify KWin starts and Xwayland is ready

### Hardware tests (Steam Deck required)
1. Game Mode + handheld — one instance, no KWin nesting
2. Game Mode + docked (1 controller) — one instance, no KWin nesting
3. Game Mode + docked (2+ controllers) — nested KWin launched, windows positioned by dex
4. Desktop Mode — no nesting, dex manages windows
5. Controller isolation — per-instance evdev access confirmed
6. Hot-plug — controller add/remove triggers layout update
7. Performance — stable FPS with 2-4 instances in nested KWin
