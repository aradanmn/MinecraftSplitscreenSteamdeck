# Research — nested-KWin Minecraft splitscreen: occlusion black-out, centered placement, gamescope 4-instance reset (2026-06-27)

Primary-source-cited investigation. Two cross-cutting corrections from verification: (1) the gamescope WSI error is **Vulkan-only** while Minecraft Java is **OpenGL** (LWJGL3/GLFW via XWayland), so the game can't emit it; (2) the 15→21 GB RAM growth is **JVM heap**, not swapchain memory.

## Problem 1 — occlusion black-out
**Root cause (ranked):**
1. **Wayland frame-callback starvation.** The protocol tells compositors to withhold `wl_surface.frame` callbacks from *fully-obscured* surfaces; a client only paints after a callback. KWin suppresses callbacks for fully-covered surfaces; on uncover it can hold a stale/black buffer and not promptly re-issue a callback+damage → stays black. Xwayland is itself a Wayland client, so the game's X11 semantics don't save it. (Inference from protocol + KWin scene behavior; no single KDE bug names this exact chain — **verify on-device:** black tile = render thread *blocked* (callback stall) vs *slow* (damage issue).)
2. Minecraft/GLFW throttling — secondary at most: `pauseOnLostFocus` doesn't stop the GL renderer; `inactivityFpsLimit:minimized` only fires when *minimized* (occluded≠minimized); GLFW has no occlusion concept.
3. Direct-scanout/unredirect — ruled out (only the visible fullscreen top window; doesn't strip covered windows).

**Fixes (don't fight it — prevent full occlusion; if needed, force a re-buffer):**
- PRIMARY: never let a tile be 100% occluded (centered placement, Problem 2) → callbacks never suppressed.
- Force re-buffer from the KWin script, ranked: (1) **minimize toggle** `w.minimized=true; w.minimized=false;` (hide/show → XWayland re-maps/re-renders); (2) **1px resize jiggle** (resize, NOT move — a move is a repaint no-op; this is the documented kwin-tiling fix); (3) raise (racy).
- WON'T work: `effects.addRepaintFull()` (repaints the scene with the existing stale buffer; also Effects API not Workspace JS), `WindowsBlockCompositing` (governs apps suspending the whole compositor, not per-surface callbacks), globally disabling compositing/occlusion (impossible on KWin 6 Wayland).
- Game-side belt-and-suspenders (`options.txt`): `pauseOnLostFocus:false`, `inactivityFpsLimit:afk` (NOT minimized), no "Dynamic FPS" mod.

## Problem 2 — map-time centered placement (the structural fix)
A **forced KWin window rule** is the only true map-time mechanism (computed in `Placement::place()` before present; Force overrides the app's own geometry). `windowAdded` script = post-map (safety-net only); global `[Windows] Placement=Centered` = bypassable fallback.

`~/.config/kwinrulesrc` (KWin 6 / Plasma 6):
```ini
[General]
count=1
rules=minecraft-center

[minecraft-center]
Description=Center Minecraft windows on map
wmclass=minecraft
wmclassmatch=2
wmclasscomplete=false
placement=5
placementrule=2
```
Enum values (read from KWin master source):
- `placement=5` = **Centered** (PlacementPolicy enum: None0 Default1 Unknown2 Random3 Smart4 Centered5 ZeroCornered6 UnderMouse7 OnMainWindow8 Maximizing9). **CRITICAL:** on Plasma 5 Centered was `6` (Cascade=5 existed); stale guides showing `6` are wrong for KWin 6.
- `placementrule=2` = **Force** (`6` = ForceTemporarily).
- `wmclassmatch=2` = **Substring**.

**VERIFY first on the Deck:** `xprop WM_CLASS` on a live splitscreen window — LWJGL3/GLFW usually reports `Minecraft`, but PolyMC/Prism Java can report `java` / `net-minecraft-…`. If `minecraft` substring misses → `wmclass=java` or regex (`wmclassmatch=3`). Frontier: a 1-frame flash at the client origin for XWayland can't be 100% ruled out from sources — combine with the grid layout so any flash never lands as a *full* occlusion.

## Problem 3 — gamescope 4-instance reset
Two decoupled phenomena:
- **WSI error** (`Creating swapchain for non-Gamescope swapchain`): from `VkLayer_FROG_gamescope_wsi.cpp::CreateSwapchainKHR` when the surface wasn't created against gamescope's socket; the layer can **`abort()`** if its message box returns Cancel — and in headless Game Mode it may not be able to show the dialog (frontier — highest-value test). **Vulkan-only**, so it's the nested compositor(s)/zink, not the GL game. `ENABLE_GAMESCOPE_WSI=1` is exported by the SteamOS session and inherited by every child.
- **Memory:** 15→21 GB ≈ JVM heap (`MaxMemAlloc=1536` ×4 = 6 GB) + GL/GTT buffers + nested-compositor copies on the **16 GB unified APU** → allocation failure / `VK_ERROR_DEVICE_LOST` / reset. Swapchain memory is ~100 MB (≈20× too small).

**Fixes:**
- Disable the WSI layer for the instances (zero benefit since surfaces are non-gamescope): `DISABLE_GAMESCOPE_WSI=1` (the layer keys on the *presence* of `disable_environment`, so `ENABLE_GAMESCOPE_WSI=0` is the WRONG off-switch), also `env -u ENABLE_GAMESCOPE_WSI`; or loader `VK_LOADER_LAYERS_DISABLE='*gamescope*'`.
- Cut memory: `-Xmx1024M -XX:MaxMetaspaceSize=256M -XX:+UseSerialGC` per instance (4 GB not 6); `RADV_SYS_MEM_LIMIT=50` (integer 10-100, default 75 — caps RADV's unified-RAM claim); lower render distance + smaller per-instance render resolution.
- Ensure GL = `radeonsi`, not zink (don't set `MESA_LOADER_DRIVER_OVERRIDE=zink`).

## What to try first, in order (cross-cutting)
1. **Forced centered window rule** (kwinrulesrc placement=5/placementrule=2) — after `xprop` WM_CLASS check. Kills Problem 1's trigger; config-only.
2. **Grid so no tile is ever 100% occluded** (side-by-side, not stacked-then-moved).
3. **Disable gamescope WSI layer** for every Minecraft/JVM process + inside bwrap: `env -u ENABLE_GAMESCOPE_WSI DISABLE_GAMESCOPE_WSI=1` (or `VK_LOADER_LAYERS_DISABLE='*gamescope*'`).
4. **Cut memory:** `-Xmx1024M` + `RADV_SYS_MEM_LIMIT=50` + lower render distance/resolution.
5. **If a tile still blacks out:** KWin-script forced re-buffer — `w.minimized` toggle, fallback 1px **resize** jiggle. Skip raise-only and `addRepaintFull`.
6. **Game-side:** `pauseOnLostFocus:false`, `inactivityFpsLimit:afk`; no Dynamic FPS; confirm radeonsi not zink.
7. **Diagnostics:** black tile blocked vs slow? does disabling WSI stop the resets? split the 6 GB via `radeontop` (GTT/VRAM) vs per-PID RSS.

_Sources: wayland-book frame-callbacks; KWin scene-items + scripting API + placement/rules source (invent.kde.org options.h/placement.cpp/rules.cpp/kwin.kcfg); gamescope VkLayer_FROG_gamescope_wsi.cpp + issues #1346/#1958; Vulkan-Loader LoaderDebugging; Mesa RADV envvars; minecraft.wiki options.txt; glfw #1828._
