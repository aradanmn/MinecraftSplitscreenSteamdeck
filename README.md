# Minecraft Splitscreen for Steam Deck

Play Minecraft **splitscreen with up to 4 people on one screen** — each player with their own controller — on a Steam Deck.

It's couch co-op for Minecraft: dock your Deck to a TV or monitor, hand everyone a controller, the screen splits between you, and you all play together on one device. No second computer needed.

> ℹ️ **Personal-use project (v1).** For people who **already own Minecraft** (see [Requirements](#requirements)). The Steam Deck is the supported device; other Linux + KDE devices are experimental.

---

## What it does

- Splits the screen so **1 to 4 players** can play Minecraft at once on a single Steam Deck.
- Each player uses **their own controller** — your section of the screen is yours.
- **Join/leave on the fly:** connect another controller and a new player's view appears; disconnect it and the screen re-tiles for whoever's left.
- **Sets itself up:** installs Minecraft (via PolyMC), Java, the controller mod, and the behind-the-scenes pieces it needs.

---

## Requirements

- A **Steam Deck** running SteamOS.
- **Docked to an external display** (TV/monitor) for multiplayer. Splitscreen is a docked feature — dock first, then launch. *(Undocked/handheld runs a single player only.)*
- **One external controller per player** — e.g. a **PS4/PS5 (DualShock 4 / DualSense), Xbox, or 8BitDo** pad, wired or Bluetooth.
- You **own Minecraft.** This tool sets up local splitscreen "seats" on a copy you own; it is **not** a way to play Minecraft without owning it.

---

## A note on controllers

- ✅ **External game controllers** (PS4/PS5, Xbox, 8BitDo, etc.) — each one becomes a player.
- ➖ **The Steam Deck's built-in controls** do **not** become a player when docked. Multiplayer needs external pads; this is by design so the Deck's own sticks don't grab a slot.
- ❌ **The Valve Steam Controller is not supported as a player** — because of how Steam routes it, the game can't use it as a regular gamepad here. Use a PS/Xbox/8BitDo-style pad instead.

### If a controller disconnects mid-game (dead battery, idle power-off)

- That player's game **keeps running** — a dropped controller never tears your session down, so nobody loses the world.
- To get back in, **reconnect the controller**; that player's screen relaunches and rejoins.
- ⚠️ **If that player is *hosting* a LAN world** (rather than everyone joining a server), reconnecting relaunches their game, which **ends the LAN world for everyone**. So **whoever hosts a LAN world should use a wired controller** (or one that won't sleep/die mid-session). Players connecting to a Minecraft server are unaffected — they just rejoin. *(Seamless reconnect that keeps a host's world alive is planned for a later version.)*

---

## Will it work on my device?

- ✅ **Steam Deck (SteamOS, Game Mode)** — yes, this is what it's built and tested for.
- ⚠️ **Other Linux + KDE Plasma handhelds/PCs** (Bazzite KDE, CachyOS with KDE, etc.) — **experimental and untested.** They use a different controller model, so it may not work yet.
- ❌ **Linux with a non-KDE desktop** (e.g. GNOME) — not supported; the splitscreen relies on KDE Plasma's window manager.

---

## How to install

On the Steam Deck, switch to **Desktop Mode**, open **Konsole** (the terminal), and run:

```sh
wget https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh
chmod +x install-minecraft-splitscreen.sh
./install-minecraft-splitscreen.sh
```

The installer downloads Minecraft and the splitscreen pieces and adds a **"Minecraft Splitscreen"** shortcut to your Steam library. It asks a couple of simple yes/no questions as it goes, and stops with a clear message if your device is missing something it needs.

---

## How to play

1. **Dock** the Steam Deck to your TV/monitor and connect your external controllers.
2. Go to **Game Mode** and launch **Minecraft Splitscreen** from your library.
3. Each connected controller gets its own section of the screen; the layout re-tiles as players join or leave.
4. Play together!

*(Each instance's very first launch downloads Minecraft's assets and lets mods finish initializing, so it can take a little while — give every player's screen time to reach the main menu before judging responsiveness. Later launches are fast once everything's cached.)*

*(To play together in the same world, one player creates a world and opens it to LAN, and the others join from the Multiplayer menu — automatic shared-world setup isn't built yet.)*

---

## Current status

v1. What works on the Deck, validated on real hardware:

- ✅ Launching from the Steam shortcut into the splitscreen environment.
- ✅ Window tiling for 1–4 players (full / half / quad) that re-flows as players join and leave — confirmed scaling 1→4.
- ✅ Per-player controller assignment — each external pad maps to its own player and only that player; the Deck's built-in controls and the Steam Controller are excluded by design. Confirmed with 4 controllers.
- ✅ Single-player handheld (undocked) mode.

Known limitations:

- 🚧 On exit, you may need to pick **Abort Game** to get back to the Steam library. The session itself tears down cleanly — this is gamescope's game-end overlay not always clearing on its own.

If you hit a rough edge, check back — fixes land in point releases.

---

## Developing & testing

The launcher does not run from your git checkout — it runs from the deployed
tree under `~/.local/share/PolyMC/`. **`git pull` is not a deploy.** After
pulling or editing, sync the deployed tree before testing:

```bash
./deploy.sh          # copy the launcher + runtime modules into place, print what changed
./deploy.sh --check  # verify the deployed tree matches the checkout (exit 1 on drift)
```

`tests/hardware/run_all.sh` runs the `--check` automatically and refuses to
start against a stale tree (`HW_SKIP_FRESHNESS=1` overrides, e.g. when stage0b
is about to run the full installer anyway).

---

## Credits & license

- Inspired by [ArnoldSmith86/minecraft-splitscreen](https://github.com/ArnoldSmith86/minecraft-splitscreen).
- Built and maintained by [aradanmn](https://github.com/aradanmn); the installer originated from [FlyingEwok](https://github.com/FlyingEwok).
- **The code, tests, and documentation in this repo were written by [Claude](https://www.anthropic.com/claude) (Anthropic's [Claude Code](https://claude.com/claude-code)).**
- Uses [PolyMC](https://github.com/PolyMC/PolyMC) and [Eclipse Temurin (Adoptium)](https://adoptium.net).

> **License:** not finalized yet — this project is not cleared for public redistribution pending license resolution of the inherited installer code. For personal use for now.
