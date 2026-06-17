# Minecraft Splitscreen Steam Deck & Linux

Run **Minecraft splitscreen (1–4 players)** on Steam Deck and Linux.

---

## Quick Install

```sh
wget https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh
chmod +x install-minecraft-splitscreen.sh
./install-minecraft-splitscreen.sh
```

Installs PolyMC, creates 4 splitscreen instances, installs Fabric and required mods. No manual Java setup needed.

### Launch

```sh
~/.local/share/PolyMC/minecraftSplitscreen.sh
```

Or launch from Steam / desktop if you enabled those integrations during install.

---

## Features

**Controller isolation** — each player's controller only controls their instance. No cross-contamination, even in Game Mode.

**1–4 player splitscreen** — instances dynamically spawn as controllers are connected. Up to 4 players simultaneously.

**Handheld → docked switching** — plug into a dock with controllers and it switches automatically. Unplug and it goes back to handheld mode.

**Gamescope support (Game Mode)** — runs correctly in Steam Deck Game Mode with a seamless launch experience.

**Mod compatibility** — core mods (Controlify, Splitscreen Support) plus optional mods like Sodium, Just Zoom, Mod Menu, and more. Custom Modrinth/CurseForge mods supported with automatic compatibility validation.

---

## Development Branches

| Branch | What's Here |
|--------|-------------|
| `main` | Stable installer — recommended for most users |
| `feat/gamescope-windowing` | Modular launcher with dynamic hot-plug controller support, docked mode, and Game Mode windowing (active development) |

---

## Required Mods

- [Controlify](https://modrinth.com/mod/controlify) — controller support
- [Splitscreen Support](https://modrinth.com/mod/splitscreen) — splitscreen rendering

## Requirements

- Linux (Steam Deck or desktop Linux)
- `bash`, `curl` or `wget`, `jq`
- `bwrap` (bubblewrap) — needed for controller isolation on feat/gamescope-windowing
- Python 3 — only for automatic Steam shortcut integration

---

## Credits

- Inspired by [ArnoldSmith86/minecraft-splitscreen](https://github.com/ArnoldSmith86/minecraft-splitscreen)
- Built and maintained by [aradanmn](https://github.com/aradanmn), originally forked from [FlyingEwok](https://github.com/FlyingEwok)
- Uses [PolyMC](https://github.com/PolyMC/PolyMC)
- Uses [Eclipse Temurin (Adoptium)](https://adoptium.net) for automatic JDK installation
