# Minecraft Splitscreen for Steam Deck & Linux

Play Minecraft **splitscreen with up to 4 people on one screen** — each player with their own controller — on a Steam Deck or a Linux PC.

It's couch co-op for Minecraft: hand everyone a controller, the screen splits between you, and you all play together on a single device. No second computer needed, and no extra Minecraft accounts to buy.

---

## What it does

- Splits the screen so **1 to 4 players** can play Minecraft at the same time on one device.
- Each player uses **their own controller** — your buttons only control your part of the screen.
- **Plug-and-play players:** connect another controller and a new player joins the screen; unplug it and they leave.
- **Sets everything up for you.** It automatically installs Minecraft, the add-ons that make splitscreen work, and the behind-the-scenes pieces it needs. You don't configure anything technical.

---

## Will it work on my device?

- ✅ **Steam Deck** — yes, this is the device it's built for. Works as-is.
- ✅ **Other Linux PCs that use the "KDE Plasma" desktop** — for example **Bazzite** (the handheld or KDE version) or **CachyOS** set up with KDE.
- ❌ **Linux PCs using a different desktop** (such as GNOME) are **not** supported — the program relies on KDE Plasma to arrange the split screen. If your system isn't compatible, the installer will tell you right away instead of failing later.

> Not sure what you have? If you're on a **Steam Deck**, you're good to go.

---

## How to install

On a Steam Deck, switch to **Desktop Mode**, open the **Konsole** app (that's the terminal), and paste in these three lines:

```sh
wget https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh
chmod +x install-minecraft-splitscreen.sh
./install-minecraft-splitscreen.sh
```

The installer handles everything — it downloads Minecraft and the splitscreen add-ons and adds a **"Minecraft Splitscreen"** shortcut to your Steam library. It will ask a couple of simple yes/no questions as it goes.

---

## How to play

1. Go back to **Game Mode** (the normal Steam Deck interface).
2. Open your Steam library and launch **Minecraft Splitscreen**.
3. Connect a controller for each player — everyone who connects gets their own section of the screen.
4. Play together!

---

## Good to know

This program is **actively being developed**. Two-player splitscreen works well today; three- and four-player support is still being polished, and the Steam Deck is the best-supported device. If you hit a rough edge, it's likely something already being worked on.

---

## Credits

- Inspired by [ArnoldSmith86/minecraft-splitscreen](https://github.com/ArnoldSmith86/minecraft-splitscreen)
- Built and maintained by [aradanmn](https://github.com/aradanmn), originally forked from [FlyingEwok](https://github.com/FlyingEwok)
- Uses [PolyMC](https://github.com/PolyMC/PolyMC) and [Eclipse Temurin (Adoptium)](https://adoptium.net)
