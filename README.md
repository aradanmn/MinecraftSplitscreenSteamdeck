# Minecraft Splitscreen Steam Deck & Linux Installer

Simple installer for running **Minecraft splitscreen (1–4 players)** on Steam Deck and Linux using **PolyMC**.

## What This Does
- Installs/updates PolyMC in `~/.local/share/PolyMC`
- Creates 4 splitscreen instances (`latestUpdate-1` to `latestUpdate-4`)
- Installs Fabric and required splitscreen mods
- Lets you choose optional compatible mods
- Lets you add custom Modrinth/CurseForge mods with compatibility checks
- Optionally adds launchers to Steam and desktop

## Core Mods (Required)
- [Controlify](https://modrinth.com/mod/controlify)
- [Splitscreen Support](https://modrinth.com/mod/splitscreen)

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
- `bash`, `curl` or `wget`, and `jq`
- Python 3 only if you want automatic Steam shortcut integration

No manual Java setup is required. The installer detects and installs the needed Java version automatically.

## Install
```sh
wget https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh
chmod +x install-minecraft-splitscreen.sh
./install-minecraft-splitscreen.sh
```

### Debug Mode
Use this if you want verbose logs:
```sh
./install-minecraft-splitscreen.sh --debug
```

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

## Launching
After install, run:
```sh
~/.local/share/PolyMC/minecraftSplitscreen.sh
```

You can also launch from Steam or desktop if you enabled those integrations.

## Install Locations
- Main directory: `~/.local/share/PolyMC/`
- Splitscreen launcher: `~/.local/share/PolyMC/minecraftSplitscreen.sh`
- Instances: `~/.local/share/PolyMC/instances/`

## Updating
Re-run the installer anytime:
```sh
./install-minecraft-splitscreen.sh
```

The installer updates instance configs and mods for the version you select, while preserving existing instance/user data where possible.

## TODO
- Explore an optional "fast launch mode" for Steam Deck that reduces startup delays where possible while keeping the current reliable default behavior unchanged.
- Investigate cross-desktop-environment fullscreen handling (GNOME and others), potentially via an optional nested-session launch mode to avoid taskbars/panels overlapping lower splitscreen instances. Idea: evaluate a lightweight nested tiling DE/compositor approach for more consistent fullscreen splits.

## Uninstall
```sh
wget https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/uninstall-minecraft-splitscreen.sh
chmod +x uninstall-minecraft-splitscreen.sh
./uninstall-minecraft-splitscreen.sh
```

Optional uninstall flags:
- `--yes`
- `--dry-run`
- `--keep-data`

## Troubleshooting
- Connect controllers before launching.
- If controller assignment seems wrong, close all instances and relaunch.
- Steam Deck users can optionally use [Steam-Deck.Auto-Disable-Steam-Controller](https://github.com/scawp/Steam-Deck.Auto-Disable-Steam-Controller) as a fallback for edge-case controller conflicts.
- Custom mods are best-effort and untested in this setup; incompatible or conflicting mods can break splitscreen behavior.

## Credits
- Inspired by [ArnoldSmith86/minecraft-splitscreen](https://github.com/ArnoldSmith86/minecraft-splitscreen)
- Built and maintained by [aradanmn](https://github.com/aradanmn), originally forked from [FlyingEwok](https://github.com/FlyingEwok)
- Uses [PolyMC](https://github.com/PolyMC/PolyMC)
- Uses [Eclipse Temurin (Adoptium)](https://adoptium.net) for automatic JDK installation
