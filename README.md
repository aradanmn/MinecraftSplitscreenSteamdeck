# Minecraft Splitscreen — Steam Deck & Linux

Automated installer for 1–4 player splitscreen Minecraft on Steam Deck and Linux.
Uses [PrismLauncher](https://prismlauncher.org/) with Fabric. A Microsoft account is required.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh | bash
```

The installer guides you through everything interactively.

## Requirements

- Linux (Steam Deck, Bazzite, SteamOS, Ubuntu, Arch, etc.)
- Internet connection
- Microsoft account (for Minecraft Java Edition)
- Java — **installed automatically** if not present
- PrismLauncher — **installed automatically** if not present (Flatpak preferred on immutable distros)

## What the Installer Does

1. Detects or installs PrismLauncher (Flatpak or AppImage)
2. Installs the correct Java version for your chosen Minecraft version
3. Lets you pick a Minecraft version (only versions compatible with all required mods are offered)
4. Creates 4 pre-configured Minecraft instances
5. Checks Modrinth and CurseForge APIs for the latest compatible mod versions and installs them
6. Generates a `minecraftSplitscreen.sh` launcher script with paths baked in
7. Optionally adds a shortcut to Steam and your desktop menu

## Mods Installed

**Required (always installed):**
- [Controllable](https://www.curseforge.com/minecraft/mc-mods/controllable) — controller support
- [Splitscreen Support](https://modrinth.com/mod/splitscreen) — splitscreen rendering
- [Fabric API](https://modrinth.com/mod/fabric-api), [Framework](https://www.curseforge.com/minecraft/mc-mods/framework) — mod dependencies

**Optional (selectable during install):**
Sodium, Sodium Extra, Reese's Sodium Options, Sodium Dynamic Lights, Mod Menu, Just Zoom, Better Name Visibility, Full Brightness Toggle, In-Game Account Switcher, Old Combat Mod, Legacy4J, and others.

Dependencies (Collective, Konkrete, YACL, etc.) are resolved and installed automatically.

## Launching

After installation, launch via:
- Steam (if you chose Steam integration)
- Desktop shortcut (if you chose to create one)
- Directly: `~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/minecraftSplitscreen.sh`

On first launch you'll be asked to choose **Static** or **Dynamic** splitscreen mode.

## Dynamic Splitscreen

In Dynamic mode, players can join and leave mid-session — no coordinated start required.

- **Connect a controller** → a new Minecraft instance launches for that player
- **Disconnect a controller** → that player's instance closes
- **Windows reposition automatically** as the player count changes:
  - 1 player: fullscreen
  - 2 players: top/bottom split
  - 3–4 players: 2×2 grid

Window repositioning uses KWin scripting on KDE/Wayland, `xdotool`/`wmctrl` on X11, or restarts instances as a fallback (Game Mode).

**Optional packages for best experience:**

| Package | Benefit | Without it |
|---|---|---|
| `inotify-tools` | Instant controller hotplug detection | 2-second polling |
| `xdotool` / `wmctrl` | Smooth X11 window repositioning | Instance restarts |
| `libnotify` | Desktop notifications on join/leave | Silent |

<details>
<summary>Install commands</summary>

```bash
# Debian/Ubuntu
sudo apt install inotify-tools xdotool wmctrl libnotify-bin

# Fedora
sudo dnf install inotify-tools xdotool wmctrl libnotify

# Arch
sudo pacman -S inotify-tools xdotool wmctrl libnotify

# openSUSE
sudo zypper install inotify-tools xdotool wmctrl libnotify-tools
```

On immutable distros (SteamOS, Bazzite, Silverblue), use your distro's layering system or Flatpak equivalents.

</details>

## Updating

Re-run the installer to update mods, change Minecraft version, or regenerate the launcher script.
Your worlds, options.txt, and accounts are preserved.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/cleanup-minecraft-splitscreen.sh -o cleanup.sh
chmod +x cleanup.sh
./cleanup.sh --dry-run   # preview what will be removed
./cleanup.sh             # remove everything (preserves Java by default)
./cleanup.sh --remove-java  # also remove Java
```

Steam shortcuts must be removed manually: **Steam → Library → right-click 'Minecraft Splitscreen' → Manage → Remove non-Steam game**.

## Installation Locations

| Install type | Path |
|---|---|
| Flatpak | `~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/` |
| AppImage | `~/.local/share/PrismLauncher/` |

The launcher script (`minecraftSplitscreen.sh`) and logs (`~/.local/share/MinecraftSplitscreen/logs/`) live inside the appropriate directory.

## Troubleshooting

- **Controllers not detected** — connect controllers before launching; in static mode the count is fixed at startup
- **Wrong controller assigned to player** — the Controllable mod's in-game device selector can reassign controllers per-instance
- **Screen doesn't reposition** — install `xdotool`/`wmctrl` (X11) or ensure KWin is running (Wayland/KDE)
- **Logs** — check `~/.local/share/MinecraftSplitscreen/logs/` for the most recent install and launcher logs

## Credits

- Original concept by [ArnoldSmith86](https://github.com/ArnoldSmith86/minecraft-splitscreen)
- Fork and major rewrite by [FlyingEwok](https://github.com/FlyingEwok)
- Current maintainer: [aradanmn](https://github.com/aradanmn)
- Launcher: [PrismLauncher](https://github.com/PrismLauncher/PrismLauncher)
