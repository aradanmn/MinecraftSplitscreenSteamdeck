# Gamescope Compositing Architecture — Research Document

**Context:** Minecraft Splitscreen Launcher for Steam Deck
**Date:** 2026-06-17
**Branch:** feat/gamescope-windowing

---

## 1. How Gamescope Compositing Works

### 1.1 Architecture Overview

Gamescope is a **Wayland compositor** that uses the `steamcompmgr` component (a fork of the original `compmgr` compositing manager) to handle X11 windows. It creates:
1. An internal **Wayland server** (via `wlserver`)
2. An **XWayland server** as a client of that Wayland server
3. Direct **DRM/KMS** or **Vulkan swapchain** output to the display

The architecture: `X11 client → XWayland → Wayland surface → steamcompmgr compositing → KMS/Vulkan`

### 1.2 Window Detection and Tracking

Gamescope maintains an internal linked list of all X11 windows:

```cpp
steamcompmgr_win_t *list;  // in xwayland_ctx_t
```

Each `steamcompmgr_win_t` stores:
- `XWindowAttributes a` — original X11 window attributes (x, y, width, height, override_redirect)
- `appID` — Steam AppID from the `STEAM_GAME` atom
- `isOverlay`, `isExternalOverlay` — overlay flags
- `isFullscreen` — from `_NET_WM_STATE_FULLSCREEN`
- `opacity` — from `_NET_WM_WINDOW_OPACITY`
- `pid`, `title`, `skipTaskbar`, `skipPager`, etc.

**The critical window geometry lifecycle:**
1. XWayland receives `XConfigureEvent` from the X11 client
2. `configure_win()` copies `ce->x, ce->y, ce->width, ce->height` directly into `w->xwayland().a`
3. `paint_window_commit()` reads `w->GetGeometry()` — which returns `(a.x, a.y, a.width, a.height)` — to compute the layer's offset and scale in the composite

**This means: when a Minecraft window calls `glfwSetWindowPos()` or you run `xdotool windowmove`, the geometry goes through:**
- X11 `ConfigureRequest` → XWayland → `ConfigureNotify` → `configure_win()` → `w->xwayland().a.{x,y,width,height}` → `GetGeometry()` → used in `paint_window_commit()` for offset computation

### 1.3 Compositing Output: The Layer Stack

Gamescope composites layers in this specific order (from `paint_all()`):

1. **Base plane** (focused window, `g_zposBase`) — the main game window, always fullscreen-scaled
2. **Override redirect plane** (`g_zposOverride`) — dropdown/popup windows rendered on top of the base plane
3. **External overlay plane** (`g_zposExternalOverlay`) — `GAMESCOPE_EXTERNAL_OVERLAY` windows
4. **Steam overlay plane** (`g_zposOverlay`) — `STEAM_OVERLAY` windows
5. **Notification plane** — focused notifications
6. **Cursor plane** (`g_zposCursor`) — always on top

**Critical finding:** In `paint_window_commit()`, when a window is the `scaleW` (focused window):
- Its geometry is ignored for offset purposes (offset is 0,0 — meaning fullscreen)
- The layer `zpos` is set to `g_zposBase` for the focused window

When a window is NOT the focus window (`w != scaleW`):
- Its `nX` and `nY` offsets ARE used: `drawXOffset += w->GetGeometry().nX * currentScaleRatio_x`
- Its `zpos` is set to `g_zposOverride`

**However**, if the window doesn't have `STEAM_GAME` set, it may never receive focus priority.

### 1.4 Window Positioning Within Composites

**Yes, xdotool windowmove/windowsize DOES affect the composited output — BUT with caveats:**

- The position/size set via `xdotool` (X11 `ConfigureRequest`) propagates through XWayland and gets stored in `w->xwayland().a.{x,y,width,height}`
- `paint_window_commit()` reads these values and applies them as layer offsets
- **But:** gamescope's focus logic will **resize the focused window to fullscreen** whenever it's determined to be a "game window" (has `STEAM_GAME` set). The relevant code at line ~3967:
  ```cpp
  if (window_is_fullscreen(ctx->focus.focusWindow) || ctx->force_windows_fullscreen) {
      XResizeWindow(ctx->dpy, ctx->focus.focusWindow->xwayland().id, fs_width, fs_height);
  }
  ```
- The window is also "nudged" to position (1,1) on first focus.

**The override redirect plane is the actual path for non-fullscreen windows.** Windows that are NOT the primary focus, but ARE override-redirect or have `skipTaskbar`/`skipPager`, get rendered as override windows using their own geometry. This is how dropdowns/popups appear above fullscreen games.

---

## 2. Atoms and Properties Used by Gamescope

### 2.1 Game Window Identification

| Atom | Internal Name | Type | Purpose |
|------|--------------|------|---------|
| `STEAM_GAME` | `gameAtom` | Cardinal (32-bit) | Steam AppID. If set > 0, window is a "game window" |
| `STEAM_BIGPICTURE` | `steamAtom` | Cardinal | Legacy Steam Big Picture indicator |
| `STEAM_OVERLAY` | `overlayAtom` | Cardinal | Steam overlay window marker |
| `GAMESCOPE_EXTERNAL_OVERLAY` | `externalOverlayAtom` | Cardinal | External overlay marker (mangoapp, etc.) |

**How STEAM_GAME works:**
When `steamMode == true` (which it is when launched via Steam):
```
appID = get_prop(ctx, w->xwayland().id, ctx->atoms.gameAtom, 0);
```
The window with `STEAM_GAME` set to a non-zero value is the **game**. It gets:
- Fullscreen resize on focus
- Priority in focus determination
- Special Z-ordering in the compositor

In non-Steam mode, `w->appID = w->xwayland().id` (window ID used as app identifier).

### 2.2 Control Atoms

| Atom | Internal Name | Purpose |
|------|--------------|---------|
| `GAMESCOPECTRL_BASELAYER_APPID` | `gamescopeCtrlAppIDAtom` | Set on root window to specify which AppID(s) control the base layer |
| `GAMESCOPECTRL_BASELAYER_WINDOW` | `gamescopeCtrlWindowAtom` | Set on root window to specify a specific X11 Window ID as the base layer |
| `GAMESCOPE_FOCUSED_APP` | `gamescopeFocusedAppAtom` | Read-only: current focused app ID |
| `GAMESCOPE_FOCUSED_WINDOW` | `gamescopeFocusedWindowAtom` | Read-only: current focused window ID |
| `GAMESCOPE_FOCUSABLE_APPS` | `gamescopeFocusableAppsAtom` | Write: list of AppIDs that can be focused |
| `GAMESCOPE_FOCUSABLE_WINDOWS` | `gamescopeFocusableWindowsAtom` | Write: list of window IDs that can be focused |

**Usage of GAMESCOPECTRL_BASELAYER_WINDOW:**
```
focusControlWindow = get_prop(ctx, ctx->root, ctx->atoms.gamescopeCtrlWindowAtom, None);
```
When set on the **root window**, gamescope uses this specific window as the base layer instead of picking the highest-priority window via focus logic. This is how third-party tools can tell gamescope "render this specific window as the game".

### 2.3 Window State Atoms

| Atom | Purpose |
|------|---------|
| `_NET_WM_STATE_FULLSCREEN` | Window wants fullscreen presentation |
| `_NET_WM_STATE_SKIP_TASKBAR` | Window is likely a popup/overlay |
| `_NET_WM_STATE_SKIP_PAGER` | Window is likely a popup/overlay |
| `_NET_WM_WINDOW_TYPE` | Window type (_NET_WM_WINDOW_TYPE_NORMAL, _NET_WM_WINDOW_TYPE_DIALOG, etc.) |
| `WM_TRANSIENT_FOR` | Dialog parent relationship |
| `_NET_WM_WINDOW_OPACITY` | Per-window opacity (used for overlay fade) |
| `OVERRIDE_REDIRECT` (in XA) | Window bypasses WM positioning (set via `xdotool set_window --overrideredirect 1`) |

### 2.4 Tuning/Control Atoms (Root Window Properties)

| Atom | Effect |
|------|--------|
| `GAMESCOPE_FORCE_WINDOW_FULLSCREEN` | When non-zero, forces ALL non-overlay windows to fullscreen |
| `GAMESCOPE_SCALING_FILTER` | Sets upscale filter (FSR, NIS, LINEAR, NEAREST) |
| `GAMESCOPE_FPS_LIMIT` | Frame rate cap |
| `GAMESCOPE_ALLOW_TEARING` | Enables VRR/tearing control |

---

## 3. xdotool Behavior Inside Gamescope's XWayland

### 3.1 What Works

- `xdotool windowmove <wid> <x> <y>` — sends `XConfigureRequest` → XWayland → `ConfigureNotify` → `configure_win()` → `w->xwayland().a.x = x, a.y = y` → **used in composite offset calculation**
- `xdotool windowsize <wid> <w> <h>` — same path, width/height stored
- `xdotool set_window --overrideredirect 1 <wid>` — sets `OverrideRedirect` which influences focus/override logic
- `xdotool windowraise <wid>` — affects stacking in XWayland's internal Z-order
- `xdotool search --pid <pid>` — works via XRes query to find windows by process
- `xdotool getwindowgeometry <wid>` — reads back stored X11 geometry (which matches what was set)

### 3.2 What Breaks

- `xdotool set_window --name` — LWJGL3 may reset `_NET_WM_NAME` on swapchain recreation, and gamescope doesn't cache it across that. Confirmed: Minecraft's `"Minecraft* 26.1.2"` title reappears after setting.
- **Position/size may be immediately overridden** if the window is the focused game window — gamescope's focus logic calls `XResizeWindow` to fullscreen on every focus event
- The "nudge" logic: on first focus, gamescope calls `XMoveWindow(ctx->dpy, focus, 1, 1)` — moving the focused game window away from (0,0)

### 3.3 The Key Constraint

Gamescope **only composites ONE window as the base layer** (the focused game window). All other X11 windows are either:
- Override redirect windows (rendered on top at their own geometry)
- Invisible/unfocused (not rendered)

**For splitscreen, the problem is fundamental:**
Gamescope expects ONE game window with ONE fullscreen surface. Non-focused windows are not independently composited as side-by-side tiles.
The override redirect path IS used for their geometry, but only for windows that are
popups/dialogs — not for a second game window that needs equal screen real estate.

---

## 4. Architecture Recommendations by Mode

### 4.1 Desktop Mode (X11/KDE Plasma)

**Strategy: Standard window manager approach**

In Desktop mode, a full X11 window manager (KWin) handles all window positioning. xdotool works as expected.

**Architecture:**
```
X11 Display (:0)
├── KWin (window manager)
├── Minecraft P1 window → xdotool position top-half
├── Minecraft P2 window → xdotool position bottom-half
└── (Optional) xdotool windowraise to manage Z-order
```

**Key facts:**
- Resolution detection via `xrandr`/`kscreen-doctor` works
- xdotool is fully reliable
- No bwrap sandbox isolation needed for display (but still needed for controllers)

**Implementation:**
- Current `window_manager.sh` works as-is
- `_get_screen_resolution()` already has xrandr fallback
- `apply_layout()` with xdotool is the right approach

### 4.2 Gamescope Mode (Steam Deck Game Mode)

**Strategy: Fullscreen stacked viewports OR Xephyr nested server**

**Option A: Single instance with mod-only viewport split (RECOMMENDED)**
Since gamescope only composites ONE game window as the base layer, and the Splitscreen Support mod controls the render viewport:
- Launch ONE Minecraft instance
- Use the mod's `splitscreen.properties` with `mode=TOP` (P1) and rely on... wait, this doesn't work for multiplayer.
- **Single-instance only** for handheld. No split needed.

**Option B: Xephyr nested X server (for docked/gamescope multi-instance)**
```
gamescope (Wayland compositor)
└── Xephyr (nested X server)
    └── Standard X11 WM (no window manager needed since Xephyr has no WM)
        ├── Minecraft P1 window
        ├── Minecraft P2 window
        └── xdotool position works normally
```
- Xephyr provides a standard X11 server where xdotool WILL work
- One extra dependency (`Xephyr` package)
- Adds ~1 frame of latency (internal compositing)
- Already confirmed approach on Steam Deck

**Option C: Native Wayland mode (future)**
If Minecraft instances run natively on Wayland (via LWJGL3's Wayland backend):
- gamescope can composite multiple Wayland surfaces
- Each surface gets its own geometry
- **Not currently supported** by LWJGL3/Minecraft on most setups

**xdotool direct testing (CURRENT APPROACH):**
The geometry DOES flow through to compositing (confirmed by source analysis), but gamescope's focus logic fights it. Need to verify if a non-focused window with `override-redirect` + `skipTaskbar` gets rendered at its set position.

### 4.3 Docked Mode (External Display, Multi-Instance)

**Strategy: Same as Gamescope but with Xephyr**

In docked mode on Steam Deck:
1. External display is connected via USB-C/HDMI
2. Gamescope can either target the external display or use Xephyr
3. For 2-4 instances, Xephyr is the most reliable path

**Recommended architecture:**
```
┌─────────────────────────────────┐
│  gamescope (or KDE Wayland)     │
│  ┌───────────────────────────┐  │
│  │ Xephyr :1 (1920×1080)     │  │
│  │ ┌─────┬─────┐            │  │
│  │ │ P1  │ P2  │            │  │
│  │ │ TOP │ BTN │            │  │
│  │ ├─────┼─────┤            │  │
│  │ │ P3  │ P4  │            │  │
│  │ │ LFT │ RGT │            │  │
│  │ └─────┴─────┘            │  │
│  └───────────────────────────┘  │
└─────────────────────────────────┘
```

**Implementation sketch:**
```bash
# Start Xephyr
Xephyr :1 -ac -screen 1920x1080 -br -reset -terminate &
sleep 1
export DISPLAY=:1

# Launch instances with display pointing to Xephyr
DISPLAY=:1 xdotool windowsize ...  # Works normally
```

### 4.4 Handheld Mode (Single Instance, No Split)

**Strategy: Direct gamescope output — easiest mode**

Since handheld requires only one player with one controller:
- Launch one Minecraft instance directly
- No window positioning needed
- The mod's `splitscreen.properties` is set to `mode=FULLSCREEN`
- No display nesting, no Xephyr

**Architecture is already correct in `handheld_flow()`:**
```bash
handheld_flow() {
    # Find the built-in controller
    spawn_instance 1 "$event_node" "$js_node"
    # Wait for exit — NO window management needed
}
```

---

## 5. Recommended Architecture Summary

| Mode | Approach | Complexity | Dependencies | Status |
|------|----------|-----------|-------------|--------|
| **Desktop** | xdotool direct (current impl) | Low | None | Works now |
| **Handheld** | Direct gamescope, no split | Low | None | Works now |
| **Gamescope (docked)** | Xephyr nested server | Medium | Xephyr | Recommended |
| **Gamescope (docked, alt)** | xdotool in gamescope (test first) | Low | None | Needs testing |

**Cross-cutting concerns:**
- All modes use bwrap sandboxing for controller isolation (already implemented)
- All modes use `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1` + `SDL_JOYSTICK_HIDAPI=0`
- State file (`splitscreen_state.json`) works across all modes
- The `GAMESCOPECTRL_BASELAYER_WINDOW` atom could be used in docked mode to tell gamescope to use Xephyr's window as the base layer

---

## 6. Questions Answered

### Does xdotool windowmove/windowsize affect composited output in gamescope?
**YES** — the geometry flows through XWayland to `steamcompmgr_win_t.a.{x,y,width,height}`, which is read by `paint_window_commit()` for offset computation. **BUT** gamescope's focus logic actively resizes the focused game window back to fullscreen. Non-focused windows with override_redirect DO get their geometry respected in the override layer. For two equal-sized game windows, this is insufficient without nesting.

### What atoms identify game windows?
- **Primary:** `STEAM_GAME` (Cardinal, set to Steam AppID) — marks the window as "the game"
- **Control:** `GAMESCOPECTRL_BASELAYER_WINDOW` (set on root window) — forces a specific X11 Window to be the base layer
- **Control:** `GAMESCOPECTRL_BASELAYER_APPID` (set on root window) — forces windows with this AppID to be base layer
- **Overlay:** `STEAM_OVERLAY`, `GAMESCOPE_EXTERNAL_OVERLAY` — marks overlay windows
- **State:** `_NET_WM_STATE_FULLSCREEN`, `_NET_WM_STATE_SKIP_TASKBAR`, `_NET_WM_WINDOW_TYPE`

### Can we use GAMESCOPECTRL_BASELAYER_WINDOW for splitscreen?
Yes — you could set `GAMESCOPECTRL_BASELAYER_WINDOW` to the Xephyr window's XID on the gamescope root window. This would tell gamescope "composite this Xephyr session window as the game," letting Xephyr's internal X11 server handle the actual splitscreen layout with xdotool. This is the most reliable path.
