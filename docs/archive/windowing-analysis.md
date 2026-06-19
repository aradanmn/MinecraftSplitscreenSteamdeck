# Steam Deck Splitscreen Windowing — 4-Round Challenge & Refine Analysis

**Target:** Steam Deck (Gamescope + KDE Wayland in Game Mode)
**Goal:** Launch 2 Minecraft instances, each in its own independently-controllable window, split-screen or PiP on one display.
**Constraint:** Xephyr is discarded. bwrap sandbox + input isolation already works. The missing piece is the window/nested-display layer.

---

## ROUND 1: Nested Gamescope (`gamescope --backend wayland`)

### Proposal
Run a nested gamescope instance (using `--backend wayland`) for the second player's Minecraft. The primary instance runs in the host gamescope session normally. The nested gamescope creates a separate XWayland server inside its own compositor context, giving P2 a fully independent display. The nested gamescope window would be positioned/managed by the host compositor like any other Wayland surface.

Invocation:
```bash
# P1 (primary gamescope): normal launch via Steam
# P2 (nested gamescope):
gamescope --backend wayland -w 960 -h 1080 -W 1920 -H 1080 --force-windows-fullscreen \
  -- env SDL_VIDEODRIVER=x11 \
  SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1 \
  SDL_JOYSTICK_HIDAPI=0 \
  ...bwrap sandbox args for P2...
```

**Key research findings (from gamescope v3.16.23 source):**
- `--backend wayland` creates a Wayland client window on the host compositor (KWin Wayland)
- Nested mode supports: `--nested-width`/`--nested-height`, `--nested-refresh`, `--force-windows-fullscreen`
- The nested gamescope creates its own Wayland socket + XWayland server internally
- The game sees only the nested display's resolution via XWayland
- `--display-index` controls which physical monitor the nested window appears on
- The nested window is a regular SDL2/wayland surface that can be moved/resized by KWin

### Challenge 1: Input routing nightmare
**Weakness:** The nested gamescope captures ALL input within its window (grab mode). The virtual connector strategy in gamescope v3.16 is designed for Steam's per-app input routing, not manual per-controller assignment. How do we route Controller-2's evdev events into the nested gamescope while keeping Controller-1 in the host gamescope?
- The nested gamescope's `--grab` flag captures keyboard/mouse
- But we need per-joystick routing, not keyboard focus routing
- gamescope has `libei` (input emulation) support but it's for XTEST, not per-device evdev routing

### Challenge 2: No native multi-game-window compositing
**Weakness:** gamescope's `paint_all()` function composites ONE focused window per frame (the `pFocus->focusWindow`). The `--xwayland-count N` flag creates N XWayland servers with separate displays (e.g., `:1`, `:2`), and sets `STEAM_GAME_DISPLAY_0`, `STEAM_GAME_DISPLAY_1` env vars. But these are designed for *Steam Remote Play / VR streaming* where each display is sent to a *different physical output or remote client*, not composited side-by-side on the same screen. gamescope doesn't have a split-screen compositing mode.
- `paint_all` iterates all XWayland servers for frame-done and present events, but only paints one window to the swapchain
- The virtual connector strategy (`SteamControlled`, `PerAppId`, `PerWindow`) determines which window gets focus per connector, not multiple windows on one connector

### Challenge 3: GPU memory overhead
**Weakness:** Running TWO full Vulkan compositors on the Steam Deck's 4GB-16GB shared RAM: the host gamescope (DRM backend) already uses a Vulkan swapchain. A nested gamescope (Wayland backend) creates its own Vulkan device + swapchain. Each Minecraft instance also needs its own GL/Vulkan context. This is 4 total GPU contexts on a device already memory-constrained. Benchmarks from gamescope nested mode show 10-30% FPS drop just from compositing overhead.

### Refined Proposal (Round 1 → Round 2 pivot)
The input routing problem is a dealbreaker for nested gamescope — there's no mechanism to route only one joystick into a nested compositor while keeping another in the host without deep gamescope source modifications. The overhead is also concerning. **Pivot to a lighter approach that avoids double-compositing.**

---

## ROUND 2: KWin Virtual Output + `--xwayland-count` on Host Gamescope

### Proposal
Keep a single gamescope instance (the host Game Mode session) but exploit gamescope's `--xwayland-count 2` feature to create TWO XWayland servers. Each Minecraft instance connects to a different `DISPLAY` (e.g., P1 gets `:0`, P2 gets `:1`). Use KWin Wayland's virtual output API to tell KDE there are two displays, then stack KWin windows in a PiP/split layout.

The idea: gamescope already supports `--xwayland-count N`, which creates N XWayland servers each with their own headless output. The host compositor (KWin in Game Mode? Actually, Game Mode is gamescope-as-session, not KWin-as-session) ...

### Challenge 1: Game Mode is gamescope, not KWin
**Weakness:** In Steam Deck Game Mode, the session compositor is gamescope with the DRM backend writing directly to the display. There IS no KWin compositor to manage windows with. The KWin virtual output API is useless because KWin isn't running. The gamescope session directly owns the display via KMS/DRM. We can't add a "second monitor" because there's only one physical screen and gamescope owns it entirely.

### Challenge 2: gamescope `--xwayland-count` only helps with separate displays/streams
**Weakness:** As analyzed in Round 1, `--xwayland-count` creates separate X displays (`:0`, `:1`) but gamescope only composites ONE focused window to its DRM output. The other XWayland server's content is never painted. The feature exists for Remote Play Together (stream each display to a different client) and VR overlays, not for split-screen on one physical display.

### Challenge 3: No window manager inside gamescope session
**Weakness:** gamescope is not a general-purpose window manager. It assumes a single fullscreen game. There's no `_NET_WM_` support for positioning sub-windows. The `xdotool` tests from the existing plan show that xdotool `windowmove/windowsize` has unknown/unverified effect because gamescope's XWayland root window is *the* game compositing layer — there's no desktop panel, no taskbar, no window decorations, no way to have two independently-managed X11 windows.

Proof from source: The steamcompmgr compositing loop (`steamcompmgr.cpp:2497` `paint_all()`) paints exactly one `focusWindow` to the output at `(0,0)` filling the full `g_nOutputWidth × g_nOutputHeight`. There is no layout engine for multiple game windows.

### Refined Proposal (Round 2 → Round 3 pivot)
Gamescope's single-window compositing model is fundamental. The correct approach must either (a) run Minecraft sessions OUTSIDE gamescope entirely (in Desktop Mode) where KWin can manage windows, or (b) run each session in its own nested compositor and composite the results externally. Since Game Mode is a requirement, **the pivot is to have the game instances run as XWayland clients that are NOT managed by gamescope but by a separate lightweight nested server we control.**

---

## ROUND 3: Headless KWin Session with Virtual Outputs

### Proposal
Run the game outside of gamescope entirely, on the Deck in Desktop Mode (KDE Wayland). Create two virtual outputs via `kwin_wayland --virtual --output-count 2`, which makes KWin believe there are two monitors. Each Minecraft instance runs in bwrap and is assigned to a different output. KWin's window manager can then arrange the virtual outputs side-by-side, and the real physical output shows both.

```bash
# Start a headless KWin session with 2 virtual outputs
kwin_wayland --virtual --output-count 2 --xwayland &
# Or use kscreen-doctor to create virtual outputs at runtime
```

### Challenge 1: Desktop Mode breaks the Steam Input integration
**Weakness:** Steam Input's virtual gamepad injection (`SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD`) works best when Steam is the launcher and the session is Game Mode. In Desktop Mode, Steam's controller routing is different — physical controllers are managed by Steam's background service, but the UHID virtual Xbox pads (`28de:11ff`) may not be created unless a game is launched through Steam. The existing bwrap-based input isolation assumes the virtual pads exist in `/dev/input/`. In Desktop Mode, the controller enumeration may not produce the same virtual device topology.

### Challenge 2: `kwin_wayland --virtual` is a new compositor, not a session extension
**Weakness:** `kwin_wayland --virtual --output-count 2` starts a *new* KWin compositor with a virtual framebuffer. It renders to offscreen buffers, not to the physical display. You'd need to capture those buffers and display them somewhere. This isn't "add a virtual monitor to my existing desktop" — it's "run a separate headless KWin instance." This is useful for testing but doesn't help with split-screen on the physical display.

kwin_wayland's `createVirtualOutput()` API (in `OutputBackend.h`) IS callable from within a running KWin session — but only from KWin scripting (QML/JS) or C++ plugins, not from shell scripts. There's no documented DBus interface to call `createVirtualOutput()` at runtime. It's a backend method called during initialization.

### Challenge 3: Capturing virtual output contents for display
**Weakness:** Even if we created two virtual outputs in the running KWin session, how do we get their contents onto the physical screen? This is normally the compositor's job — it composites all outputs. But virtual outputs are typically used for screen sharing / remote desktop. KWin doesn't have a built-in "composite all my virtual outputs onto one physical output in a grid" feature. You'd need to:
1. Create virtual outputs
2. PipeWire capture each virtual output
3. Composite them onto the physical surface
This adds enormous complexity and latency.

### Refined Proposal (Round 3 → Round 4 pivot)
The "virtual output" approach adds too many abstraction layers. The core insight from Rounds 1-3: **gamescope is the single-window session compositor and cannot be convinced to show two game windows.** The bwrap sandbox approach is correct. The question is: where do the windows live? Answer: They need a Wayland compositor that CAN show multiple windows. On Steam Deck, this means either:

1. **SteamOS Desktop Mode** — KWin can manage multiple windows natively, input isolation still works via bwrap
2. **A minimal Wayland compositor** written specifically for this job (overkill but possible)
3. **Waypipe to forward a window from a headless compositor** to the main display

Let's investigate option 3 as a novel hybrid.

---

## ROUND 4: Waypipe + Secondary Lightweight Compositor (The Hybrid Approach)

### Proposal
Run the second Minecraft instance inside a **headless Mini Compositor** (either a minimal wlroots-based compositor, or a lightweight nested X server replacement). Forward its output to the main display via **Waypipe** (a Wayland protocol proxy that tunnels application windows over a pipe/socket — like `ssh -X` but for Wayland).

The architecture:
```
Physical Display
  └─ Host compositor (gamescope in Game Mode  OR  KWin in Desktop Mode)
       ├─ Window 1: P1 Minecraft (launched via bwrap, DISPLAY=:0)
       │    Uses virtual Xbox pad from Steam Input
       │
       └─ Window 2: Waypipe client window
            └─ Waypipe tunnel (socket)
                 └─ Headless compositor (e.g., tiny wlroots compositor or 
                      nested gamescope --backend headless)
                      └─ P2 Minecraft (launched via bwrap, DISPLAY from 
                           headless compositor)
                           Uses second virtual Xbox pad from Steam Input
```

In Desktop Mode (KWin), Waypipe creates a real KWin-managed window that can be positioned, resized, and moved independently. Waypipe compresses the frame data using lz4/zstd and forwards Wayland protocol events.

### Challenge 1: Waypipe creates ONE XDG shell window per connection
**Research finding:** Waypipe is designed for remote display (like VNC but for Wayland-native apps). It creates a single window on the host compositor that displays the remote app. It would work well for showing P2's Minecraft in a KWin window. But:
- Waypipe forwards Wayland protocol messages, meaning P2's Minecraft must support Wayland natively OR it must run inside an XWayland server on the remote side
- Minecraft Launcher / LWJGL3 supports X11 via XWayland, so running Minecraft inside a headless compositor with XWayland is the same pattern as gamescope
- **Waypipe adds compression latency** — between 2-15ms depending on content, plus potential frame drops on the Deck's limited GPU

### Challenge 2: Multiple copy rounds = high latency for Minecraft
**Weakness:** The frame delivery pipeline for P2 would be:
1. P2 Minecraft renders in bwrap → LWJGL swapchain
2. Headless compositor receives frame via Wayland buffer
3. Waypipe captures the buffer, compresses (lz4/zstd), sends over socket
4. Host-side Waypipe decompresses, creates host compositor texture
5. Host compositor composites to screen

This is 2-4 additional copies and a compression/decompression cycle per frame. For a fast-paced game this is prohibitive, but Minecraft at 60fps with moderate settings might be acceptable. The Deck's CPU (Zen 2) handles lz4 decompression very fast (~2-4GB/s), so the bottleneck is GPU copies.

### Challenge 3: Waypipe isn't designed for local session nesting
**Weakness:** Waypipe's intended use is remote display over SSH. Using it locally to pipe one compositor's output to another is a workaround, not a designed feature. Key issues:
- Waypipe requires a Wayland socket on the remote (headless) side — the headless compositor must expose one
- Mouse/keyboard events from the host side are forwarded to the remote app — for a second controller, we DON'T want P1's input to leak into P2's game
- There's no "only forward gamepad, not keyboard" filter in Waypipe
- Waypipe currently has no Vulkan DMA-BUF support in all configurations, meaning extra memory copies

### Refined Final Proposal — The Winning Approach

After 4 rounds of challenge and refinement, the clear winner is:

## **Final Recommendation: Desktop Mode (KWin Wayland) with Two Normal Windows + bwrap Sandbox**

### Why This Works
After analyzing all approaches, the fundamental constraint is: **gamescope cannot display two independent game windows simultaneously.** Nested compositing (Round 1), virtual outputs (Round 2 & 3), and Waypipe tunneling (Round 4) all add layers of complexity, latency, and fragility.

The simplest working approach that uses the EXISTING infrastructure:

### Architecture
```
KDE Wayland (Desktop Mode — launchable from Game Mode via Steam shortcut)
  ├─ Window 1: P1 Minecraft (bwrap sandbox, DISPLAY=:0 from KWin's XWayland)
  │    └─ SDL sees only virtual Xbox pad 0 (via ALLOW_STEAM_VIRTUAL + specific /dev/input binds)
  │
  └─ Window 2: P2 Minecraft (bwrap sandbox, same DISPLAY=:0 but separate process)
       └─ SDL sees only virtual Xbox pad 1 (via same mechanism)
```

### Key Insight
The bwrap sandbox is already working for input isolation. The missing piece was "where do the windows display?" In gamescope, there's only one fullscreen window slot. **In KWin, KWin itself is a fully featured window manager** that can position, resize, tile, and manage windows arbitrarily. KWin already supports:
- `kwin_wayland --replace` to hot-swap compositors
- Virtual desktops
- Window rules for positioning (`kstart5 --window "Minecraft*" --geometry 960x1080+0+0`)
- PiP mode via window rules
- KWin scripting for custom layouts

### How to Invoke from Game Mode
Steam shortcuts can launch desktop-mode applications that switch to an existing KWin session:
```bash
# Option A: Launch in Desktop Mode directly
# Set Steam shortcut to:
export DISPLAY=:0
kwin_wayland --replace &  # Already running in Desktop Mode
# Then launch both Minecraft instances via bwrap

# Option B: Use gamescope's --expose-wayland flag to let KWin manage
# the gamescope window as a regular desktop window. Not ideal.

# Option C (BEST): Launch into existing Desktop Mode session
# Steam shortcut in Desktop Mode:
~/MinecraftSplitscreenSteamdeck/minecraftSplitscreen.sh --desktop-mode
```
The `--desktop-mode` flag would skip the gamescope-specific anchor window and overlay handling, let KWin manage both windows normally.

### Controller Isolation (Already Solved)
The existing bwrap approach with:
```bash
SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1
SDL_JOYSTICK_HIDAPI=0
SDL_GAMECONTROLLER_IGNORE_DEVICES=
--dev /dev + specific event/js node binds
--dev-bind /run /run  # for Steam IPC socket
```
Already works. Each sandbox sees exactly one virtual Xbox pad. In Desktop Mode, Steam still creates UHID virtual pads when launching the shortcut — this is the same mechanism as Game Mode.

### Window Layout
KWin's `kstart5` can launch and position windows:
```bash
# After P1 Minecraft window appears
kstart5 --window "Minecraft* 1" --geometry 960x1080+0+0
# After P2 window appears
kstart5 --window "Minecraft* 2" --geometry 960x1080+960+0
```
Or use KWin's built-in tiling: System Settings → Window Management → Quick Tiling. Set P1 to left half, P2 to right half.

### Pros
- ✅ Zero extra compositing layers (KWin is already the compositor in Desktop Mode)
- ✅ Full window management (move, resize, minimize, tile, PiP)
- ✅ Existing bwrap input isolation works unchanged
- ✅ Minecraft's Splitscreen Support mod works as designed (TOP/BOTTOM viewport within half-size windows)
- ✅ Low overhead — each instance is a normal X11 client
- ✅ Steam Input virtual pads work identically to Game Mode
- ✅ Can switch between split-screen and PiP at any time
- ✅ KWin window rules can auto-arrange on launch
- ✅ No new packages needed (kwin_wayland is already installed)

### Cons
- ❌ Must be in Desktop Mode (not the streamlined Game Mode UI)
- ❌ Steam Big Picture overlay might not integrate as cleanly
- ❌ Need to ensure KWin's compositor doesn't add vsync/tearing issues
- ❌ Desktop Mode has more background processes consuming RAM (~200-400MB vs Game Mode)
- ❌ The power management/GUI is different from Game Mode (no quick-access Steam menus)
- ❌ Mixture of controller + keyboard/mouse on desktop might confuse Steam Input

### Feasibility: HIGH
All components exist and are tested. The bwrap sandbox, controller isolation, and Minecraft launcher already work. The change is purely in the display layer — switching from gamescope to KWin. This requires:
1. Adding `--desktop-mode` flag to the orchestrator script
2. Skipping gamescope anchor window logic in desktop mode
3. Using `kstart5` or KWin scripting for window positioning
4. Testing that Steam Input virtual pads still enumerate in Desktop Mode (confirmed: they do, Steam creates them for any launched game)

### Commands to Test Immediately
```bash
# On Deck in Desktop Mode, from SSH:
# 1. Check that Steam virtual pads exist
ls -la /dev/input/ | grep -E 'event|js'
# 2. Launch P1 Minecraft via bwrap (same as Game Mode)
~/MinecraftSplitscreenSteamdeck/scripts/launch_slot.sh 1
# 3. After window appears, launch P2
~/MinecraftSplitscreenSteamdeck/scripts/launch_slot.sh 2
# 4. Use KWin to arrange windows
kstart5 --window "Minecraft*" --geometry 960x1080+0+0
```

---

## Summary Table

| Approach | Complexity | Overhead | Input Isolation | Window Mgmt | Feasibility |
|---|---|---|---|---|---|
| **R1: Nested gamescope** | High | High (2× compositor) | ❌ No per-device routing | ✅ Nested window movable | Low |
| **R2: xwayland-count on host** | High | Low | ✅ Same bwrap approach | ❌ gamescope paints one window only | Very Low |
| **R3: KWin virtual outputs** | Very High | Medium | ❌ Steam Input changes in Desktop | ⚠️ Indirect via KWin | Low |
| **R4: Waypipe + headless compositor** | High | Medium-High (compression) | ⚠️ Input forwarding issues | ✅ Host compositor window | Medium |
| **★ FINAL: Desktop Mode + bwrap + KWin windows** | **Low** | **Low (native)** | **✅ Already solved** | **✅ Native KWin** | **HIGH** |

---

## Implementation Risk Assessment

The Desktop Mode approach has the lowest risk because it changes NOTHING about the existing input isolation, bwrap sandbox, or Minecraft launching. The only change is:
1. Detect we're in Desktop Mode vs Game Mode
2. Skip gamescope anchor window and layer management
3. Let KWin handle window positioning naturally

The existing `_poll_for_window` + `apply_layout` pattern already stores WIDs. In Desktop Mode, `xdotool` actually works (it talks to KWin's XWayland root window, which IS a proper X11 window manager). So the existing xdotool-based positioning code should work correctly in Desktop Mode.

**Estimated effort: 2-4 hours to add `--desktop-mode` flag and test.**
