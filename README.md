# Minecraft Splitscreen Steam Deck & Linux

Simple installer and advanced modular launcher for running **Minecraft splitscreen (1–4 players)** on Steam Deck and Linux.

- **Install:** Run the installer on `main` branch
- **Development:** Branch `feat/gamescope-windowing` — modular bwrap launcher with controller isolation, gamescope anchor window, dynamic hot-plug

---

## Quick Install

```sh
wget https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh
chmod +x install-minecraft-splitscreen.sh
./install-minecraft-splitscreen.sh
```

Installs PolyMC, creates 4 splitscreen instances, installs Fabric + required mods.

### Launching

```sh
~/.local/share/PolyMC/minecraftSplitscreen.sh
```

Or launch from Steam / desktop if you enabled those integrations during install.

---

## Development Branches

### `feat/gamescope-windowing` (Active Development)

A rewrite of the splitscreen launcher using **bwrap (bubblewrap) sandboxes** for per-instance controller isolation. Each Minecraft instance runs inside its own bwrap sandbox with only its assigned controller's `/dev/input/event*` and `/dev/input/js*` nodes visible.

**Key Features:**
- **Per-instance bwrap sandboxes** — `--dev /dev` wipes /dev; only the assigned controller's event/js nodes are bound
- **Controller isolation via env vars** — explicitly sets `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1`, `SDL_GAMECONTROLLER_IGNORE_DEVICES=`, `SDL_JOYSTICK_HIDAPI=0` to override Steam's inherited environment
- **Deck built-in masking** — built-in controls explicitly masked with `--bind /dev/null` in every external-controller sandbox
- **Dynamic hot-plug** — controllers can be added/removed mid-session; instances spawn/teardown automatically (up to 4)
- **Gamescope anchor window** — GTK black window + `GAMESCOPECTRL_BASELAYER_WINDOW` atom dismisses Steam's loading overlay in Game Mode
- **PID-based window discovery** — finds Minecraft windows by Java PID (LWJGL3 compatible), stores WID in state file for layout
- **Event-driven layout** — `_poll_for_window` → `apply_layout` triggered on window appear, not polling
- **Handheld ↔ docked mode switching** — DRM sysfs + controller-count override for gamescope; hot-swaps between modes
- **PolyMC QSingleApplication isolation** — `--tmpfs /tmp` prevents cross-instance socket conflicts

**Module Architecture:**
```
minecraftSplitscreen.sh          ← Orchestrator, FIFO event loop
modules/
  controller_monitor.sh          ← udevadm device enumeration + hot-plug
  dock_detection.sh              ← DRM sysfs: docked vs handheld
  instance_lifecycle.sh          ← bwrap sandbox launch/teardown, state
  window_manager.sh              ← xdotool layout computation
  watchdog.sh                    ← Crash detection (SLOT_DIED via FIFO)
tests/
  hardware/                      ← Full hardware test suite
    run_all.sh, stage0-5.sh      ← Automated + human-in-loop testing
  gamescope-xdotool-test.sh      ← xdotool geometry test for gamescope
  test_*.sh                      ← Unit tests
```

**State file:** `~/.local/share/PolyMC/splitscreen_state.json`  
**Session log:** `~/splitscreen-session.log`

**To test on Steam Deck:**
```bash
cd ~/MinecraftSplitscreenSteamdeck
git pull origin feat/gamescope-windowing
```
Then launch from Steam Game Mode with external display + controllers connected.

### `feat/controlify-isolation`

Alternative approach focused on controller isolation using generated launcher scripts. Uses `SDL_JOYSTICK_HIDAPI=0` + bwrap evdev masking (no `ALLOW_STEAM_VIRTUAL`). Has a `launcher_script_generator.sh` that produces self-contained launcher scripts. Less integrated with gamescope windowing than the gamescope-windowing branch.

---

## Core Mods (Required)

- [Controlify](https://modrinth.com/mod/controlify) — controller support with per-instance isolation
- [Splitscreen Support](https://modrinth.com/mod/splitscreen) — splitscreen rendering (viewports: TOP/BOTTOM/QUAD)

## Optional Mods

- [Better Name Visibility](https://modrinth.com/mod/better-name-visibility)
- [Full Brightness Toggle](https://modrinth.com/mod/full-brightness-toggle)
- [In-Game Account Switcher](https://modrinth.com/mod/in-game-account-switcher)
- [Just Zoom](https://modrinth.com/mod/just-zoom)
- [Mod Menu](https://modrinth.com/mod/modmenu)
- [Old Combat Mod](https://modrinth.com/mod/old-combat-mod)
- [Reese's Sodium Options](https://modrinth.com/mod/reeses-sodium-options)
- [Sodium](https://modrinth.com/mod/sodium)
- [Sodium Dynamic Lights](https://modrinth.com/mod/sodium-dynamic-lights)
- [Sodium Extra](https://modrinth.com/mod/sodium-extra)
- [Sodium Extras](https://modrinth.com/mod/sodium-extras)

## Requirements

- Linux (Steam Deck or desktop Linux)
- Internet connection for install/update
- `bash`, `curl` or `wget`, `jq`, `bwrap` (bubblewrap, for controller isolation on feat/gamescope-windowing)
- Python 3 only if you want automatic Steam shortcut integration or xdotool testing

No manual Java setup is required. The installer detects and installs the needed Java version automatically.

---

## How Installation Works

1. Downloads/updates PolyMC
2. Lets you pick a compatible Minecraft version
3. Detects/installs the correct Java version
4. Checks mod compatibility and lets you choose optional mods
5. Optionally accepts custom mods (URL/ID), validates compatibility, and warns about risk
6. Creates/updates 4 manual PolyMC instances with Fabric
7. Installs mods and dependencies
8. Optionally adds Steam + desktop shortcuts

### Custom Mod Input Formats

- Easiest CurseForge format: paste only the numeric project ID (example: `422301`)
- Easiest Modrinth format: paste mod URL or slug (example: `https://modrinth.com/mod/sodium` or `sodium`)
- Also supported: `mr:<slug-or-id>` and `cf:<id>`

Quick examples:
- `422301`
- `sodium`
- `https://modrinth.com/mod/sodium`
- `cf:422301`

Custom mods are validated against Fabric and your exact selected Minecraft version. If incompatible, the installer lets you skip it or stop. If the mod supports Fabric but not your selected Minecraft version, it also offers switching to a supported version.

Minecraft version selection is list-based (no manual custom version entry).  
If a custom mod is incompatible, you can choose to switch versions and the installer will show only versions that support both core mods and that requested custom mod.

---

## Install Locations

- Main directory: `~/.local/share/PolyMC/`
- Splitscreen launcher: `~/.local/share/PolyMC/minecraftSplitscreen.sh`
- Instances: `~/.local/share/PolyMC/instances/`
- Development repo: `~/MinecraftSplitscreenSteamdeck/` (if cloned)

## Updating

Re-run the installer anytime:
```sh
./install-minecraft-splitscreen.sh
```

For the development launcher (feat/gamescope-windowing):
```bash
cd ~/MinecraftSplitscreenSteamdeck && git pull origin feat/gamescope-windowing
```

## Uninstall

```sh
wget https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/uninstall-minecraft-splitscreen.sh
chmod +x uninstall-minecraft-splitscreen.sh
./uninstall-minecraft-splitscreen.sh
```

Optional flags: `--yes`, `--dry-run`, `--keep-data`

## Troubleshooting

- Connect controllers before launching.
- If controller assignment seems wrong, close all instances and relaunch.
- Steam Deck users can optionally use [Steam-Deck.Auto-Disable-Steam-Controller](https://github.com/scawp/Steam-Deck.Auto-Disable-Steam-Controller) as a fallback for edge-case controller conflicts.
- For feat/gamescope-windowing: session log at `~/splitscreen-session.log` and state at `~/.local/share/PolyMC/splitscreen_state.json`
- Custom mods are best-effort and untested in this setup; incompatible or conflicting mods can break splitscreen behavior.

## Credits

- Inspired by [ArnoldSmith86/minecraft-splitscreen](https://github.com/ArnoldSmith86/minecraft-splitscreen)
- Built and maintained by [aradanmn](https://github.com/aradanmn), originally forked from [FlyingEwok](https://github.com/FlyingEwok)
- Uses [PolyMC](https://github.com/PolyMC/PolyMC)
- Uses [Eclipse Temurin (Adoptium)](https://adoptium.net) for automatic JDK installation
