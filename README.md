# Minecraft Splitscreen for Steam Deck

Play Minecraft **splitscreen with up to 4 people on one screen** — each player with their own controller — on a Steam Deck.

It's couch co-op for Minecraft: dock your Deck to a TV or monitor, hand everyone a controller, the screen splits between you, and you all play together on one device. No second computer needed.

> ℹ️ **Personal-use project (v1.2).** For people who **already own Minecraft** (see [Requirements](#requirements)). The Steam Deck is the supported device; other Linux + KDE devices are experimental.

---

## What it does

- Splits the screen so **1 to 4 players** can play Minecraft at once on a single Steam Deck.
- Each player uses **their own controller** — your section of the screen is yours.
- **Join/leave on the fly:** connect another controller and a new player's view appears; disconnect it and the screen re-tiles for whoever's left.
- **Dead battery doesn't end your game:** reconnect the same controller and you pick up where you left off — same world, same screen, no relaunch.
- **Frame rate matched to your screen:** each player's game caps to the display's actual refresh rate instead of rendering frames nobody sees, which is what keeps four games at once comfortable.
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
- ➖ **Four players max.** Connect a 5th controller and nothing happens — four is the limit (the couch co-op standard, and the Deck's performance ceiling for four simultaneous games).
- ➖ **The Steam Deck's built-in controls** do **not** become a player when docked. Multiplayer needs external pads; this is by design so the Deck's own sticks don't grab a slot.
- ❌ **The Valve Steam Controller is not supported as a player** — because of how Steam routes it, the game can't use it as a regular gamepad here. Use a PS/Xbox/8BitDo-style pad instead.

### If a controller disconnects mid-game (dead battery, idle power-off)

- That player's game **keeps running** — a dropped controller never tears your session down, so nobody loses the world.
- To get back in, **reconnect the same controller.** It reclaims its own screen and you carry on: the world stays loaded, nothing relaunches, and the other players never notice. This works because each player's game is bound to a stand-in controller that stays put while the real pad comes and goes.
- Because nothing relaunches, **a player hosting a LAN world can drop and come back without ending the world** for everyone else. (Earlier versions relaunched on reconnect and needed a wired pad for the host — that caveat is gone as of v1.2.)
- ➖ **Reconnect a *different* controller** and it's treated as a new arrival: it takes over a screen that was just freed, or starts a new player if there's room. Substituting a different *kind* of pad (say an Xbox pad for a PS4 one) is the rough edge — coming back with the pad you left with is the smooth path.
- ⚠️ **If two or more controllers drop at the same time** and then reconnect, they can land on each other's screens — one player may end up unable to control their game. Restart that player's instance to sort it out. Reconnecting one pad at a time (the usual case) is unaffected.

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

Part way through it builds a small input helper (`evsieve` — the piece that keeps your controller's slot alive across a disconnect) in a container, which takes a couple of minutes and prints progress while it works.

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

v1.2. What works on the Deck, validated on real hardware:

- ✅ Launching from the Steam shortcut into the splitscreen environment.
- ✅ Window tiling for 1–4 players (full / half / quad) that re-flows as players join and leave — confirmed scaling 1→4.
- ✅ Per-player controller assignment — each external pad maps to its own player and only that player; the Deck's built-in controls and the Steam Controller are excluded by design. Confirmed with 4 controllers.
- ✅ **Seamless reconnect** — a controller that dies or powers off mid-game reclaims its own screen when it comes back, with the world still loaded and nothing relaunched. Confirmed in a live 4-player game.
- ✅ Per-player frame rate capped to the live display refresh, which is what makes four simultaneous games sit comfortably inside the Deck's budget.
- ✅ Single-player handheld (undocked) mode.

Known limitations:

- 🚧 On exit, you may need to pick **Abort Game** to get back to the Steam library. The session itself tears down cleanly — this is gamescope's game-end overlay not always clearing on its own.
- 🚧 Two or more controllers dropping *at the same time* can swap screens on reconnect ([#151](https://github.com/aradanmn/MinecraftSplitscreenSteamdeck/issues/151)) — restart the affected player's instance.
- 🚧 Launching docked with **no external controller connected** exits without saying why ([#125](https://github.com/aradanmn/MinecraftSplitscreenSteamdeck/issues/125)). Connect a pad before launching.
- 🚧 Undocking mid-session moves the game to the Deck's screen, but re-docking does not move it back ([#134](https://github.com/aradanmn/MinecraftSplitscreenSteamdeck/issues/134)). Dock before you launch and stay docked.

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

**Escape hatch.** Seamless reconnect is on by default (`MCSS_CONTROLLER_PROXY=1`).
Setting `MCSS_CONTROLLER_PROXY=0` reverts to binding each player's physical pad
directly — no reconnect, a dropped controller stays dropped until relaunch — which
is useful for isolating whether a controller problem comes from the proxy layer.

---

## Credits & license

- Inspired by [ArnoldSmith86/minecraft-splitscreen](https://github.com/ArnoldSmith86/minecraft-splitscreen).
- Built and maintained by [aradanmn](https://github.com/aradanmn); the installer originated from [FlyingEwok](https://github.com/FlyingEwok).
- **The code, tests, and documentation in this repo were written by [Claude](https://www.anthropic.com/claude) (Anthropic's [Claude Code](https://claude.com/claude-code)).**
- Uses [PolyMC](https://github.com/PolyMC/PolyMC) and [Eclipse Temurin (Adoptium)](https://adoptium.net).

> **License / distribution.** This project began as a fork of [FlyingEwok's](https://github.com/FlyingEwok/MinecraftSplitscreenSteamdeck)
> installer, which carries no license (all-rights-reserved). The runtime and architecture
> here are original; several installer/launcher files remain derivative work (see
> [`docs/DERIVATION-AUDIT-2026-07-22.md`](docs/DERIVATION-AUDIT-2026-07-22.md)). Because of
> that, **this project lives only as a public GitHub repository — it is not distributed as a
> standalone application** and is offered for personal use. Cloning and running it from
> GitHub, with credit to FlyingEwok, is the intended and only distribution channel. A
> permissive license may be adopted if the upstream author licenses the original code.
