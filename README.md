# Minecraft Splitscreen Steam Deck & Linux Installer

This project provides an easy way to set up splitscreen Minecraft on Steam Deck and Linux using an optimized dual-launcher approach. It supports 1–4 players, controller detection, and seamless integration with Steam Game Mode and your desktop environment.

## Features
- **Automatic Java Installation:** Detects required Java version and installs automatically (no manual setup required)
- **Optimized Installation:** Uses PrismLauncher for automated instance creation, then switches to PollyMC for gameplay
- **Auto-Generated Launcher Script:** The splitscreen launcher is generated at install time with correct paths baked in - no hardcoded paths
- **Flatpak & AppImage Support:** Works with both Flatpak and AppImage installations of PollyMC and PrismLauncher
- **Smart Launcher Detection:** Automatically detects existing launcher installations and uses them
- Launch 1–4 Minecraft instances in splitscreen mode with proper Fabric support
- Automatic controller detection and per-player config
- Works on Steam Deck (Game Mode & Desktop Mode) and any Linux PC
- Optionally adds a launcher to Steam and your desktop menu
- Handles KDE/Plasma quirks for a clean splitscreen experience when running from Game Mode
- **Version Tracking:** Generated scripts include version, commit hash, and generation date for troubleshooting
- **Fabric Loader:** Complete dependency chain implementation ensures mods load and function correctly
- **Automatic Dependency Resolution:** Uses live API calls to discover and install all mod dependencies without manual maintenance
- **Smart Cleanup:** Automatically removes temporary files and directories after successful setup

## Dynamic Splitscreen Mode (v3.0.0)

Version 3.0.0 introduces **Dynamic Splitscreen** - players can now join and leave mid-session without everyone needing to start at the same time.

### How It Works

1. **Launch the game** - Choose "Dynamic" mode when prompted (or press 2)
2. **Start playing** - The first controller detected launches Player 1 in fullscreen
3. **Players join** - When a new controller connects, a new Minecraft instance launches and all windows reposition automatically
4. **Players leave** - When a player quits Minecraft, remaining windows expand to use the available space
5. **Session ends** - When all players have exited, the launcher closes

### Window Repositioning

The system automatically repositions windows based on player count:
- **1 player**: Fullscreen
- **2 players**: Top/Bottom split
- **3-4 players**: Quad split (2x2 grid)

**Desktop Mode (X11)**: Uses `xdotool` or `wmctrl` for smooth, non-disruptive window repositioning.

**Steam Deck Game Mode**: Restarts instances with new positions (the splitscreen mod only reads configuration at startup).

### Requirements for Dynamic Mode

For the best experience, install these optional packages:

```bash
# Debian/Ubuntu
sudo apt install inotify-tools xdotool wmctrl libnotify-bin

# Fedora
sudo dnf install inotify-tools xdotool wmctrl libnotify

# Arch
sudo pacman -S inotify-tools xdotool wmctrl libnotify
```

- `inotify-tools`: Efficient controller hotplug detection (falls back to polling if unavailable)
- `xdotool`/`wmctrl`: Smooth window repositioning on X11
- `libnotify`: Desktop notifications when players join/leave

### Limitations

- **Wayland**: External window management may not work on pure Wayland; XWayland apps typically work
- **Game Mode**: Window repositioning requires restarting instances (brief interruption)
- **Maximum 4 players**: Hardware and mod limitation

## Requirements
- Linux (Steam Deck or any modern distro)
- Internet connection for initial setup
- **Java** (automatically installed if not present - no manual setup required)
- *Steam Deck users: For proper controller counting, you must disable the built-in Steam Deck controller when an external controller is connected. See [Steam-Deck.Auto-Disable-Steam-Controller](https://github.com/scawp/Steam-Deck.Auto-Disable-Steam-Controller).*

## Installation Process
The installer uses an **optimized hybrid approach** combining the strengths of two different launchers:

### Why the Hybrid Approach?

Both launchers are essentially the same program with one key difference:

**PrismLauncher** has excellent automation but requires Minecraft licenses:
- ✅ **Excellent CLI automation** - Reliable command-line instance creation
- ✅ **Robust Fabric integration** - Proper mod loader dependency chains
- ❌ **Requires Minecraft license** - Must link a paid Microsoft account before creating offline accounts

**PollyMC** is identical but doesn't require licenses:
- ✅ **No license verification** - Can create offline accounts immediately without any Microsoft account linking
- ❌ **No CLI automation** - Manual setup required for instances

### Our Solution: Best of Both Worlds

1. **PrismLauncher CLI** - For automated instance creation with proper Fabric setup
2. **PollyMC** - For splitscreen gameplay (no forced login, offline-friendly)
3. **Smart Cleanup** - Removes PrismLauncher after successful PollyMC setup

This hybrid approach ensures reliable automated installation while providing the optimal splitscreen gaming experience.

## What gets installed
- [PollyMC](https://github.com/fn2006/PollyMC) AppImage (primary launcher)
- **Minecraft version:** User-selectable (defaults to latest stable release, with 4 separate instances for splitscreen)
- **Fabric Loader:** Complete dependency chain including LWJGL 3, Minecraft, Intermediary Mappings, and Fabric Loader
- **Mods included (automatically installed):**
  - [Controllable](https://www.curseforge.com/minecraft/mc-mods/controllable) - Required for controller support
  - [Splitscreen Support](https://modrinth.com/mod/splitscreen) - Required for splitscreen functionality (preconfigured for 1–4 players)
- **Optional mods (selectable during installation):**
  - [Better Name Visibility](https://modrinth.com/mod/better-name-visibility)
  - [Full Brightness Toggle](https://modrinth.com/mod/full-brightness-toggle)
  - [In-Game Account Switcher](https://modrinth.com/mod/in-game-account-switcher)
  - [Just Zoom](https://modrinth.com/mod/just-zoom)
  - [Legacy4J](https://modrinth.com/mod/legacy4j)
  - [Mod Menu](https://modrinth.com/mod/modmenu)
  - [Old Combat Mod](https://modrinth.com/mod/old-combat-mod)
  - [Reese's Sodium Options](https://modrinth.com/mod/reeses-sodium-options)
  - [Sodium](https://modrinth.com/mod/sodium)
  - [Sodium Dynamic Lights](https://modrinth.com/mod/sodium-dynamic-lights)
  - [Sodium Extra](https://modrinth.com/mod/sodium-extra)
  - [Sodium Extras](https://modrinth.com/mod/sodium-extras)
- **Mod dependencies (automatically installed when needed):**
  - [Collective](https://modrinth.com/mod/collective) - Required by several optional mods
  - [Fabric API](https://modrinth.com/mod/fabric-api) - Required by most Fabric mods
  - [Framework](https://www.curseforge.com/minecraft/mc-mods/framework) - Required by Controllable
  - [Konkrete](https://modrinth.com/mod/konkrete) - Required by some optional mods
  - [Sodium Options API](https://modrinth.com/mod/sodium-options-api) - Required by Sodium-related mods
  - [YetAnotherConfigLib](https://modrinth.com/mod/yacl) - Required by several optional mods
  - *Note: These dependencies are automatically downloaded when a mod that requires them is selected*

## Installation Features
- **CLI-driven instance creation:** Automated setup using PrismLauncher's command-line interface
- **Intelligent version selection:** Only offers Minecraft versions that are fully compatible with both required splitscreen mods (Controllable and Splitscreen Support)
- **Fabric compatibility verification:** All mods are filtered to ensure they're Fabric-compatible versions
- **Automatic dependency resolution:** Uses Modrinth and CurseForge APIs to automatically discover and install all required mod dependencies
- **Dependency chain validation:** Proper Fabric Loader setup with LWJGL 3, Intermediary Mappings, and all required dependencies
- **Fallback mechanisms:** Manual instance creation if CLI fails, with multiple retry strategies
- **Smart cleanup:** Automatically removes temporary PrismLauncher files after successful PollyMC setup

## Installation
1. **Quick Install (Recommended):**
   
   Run this single command to download and execute the installer:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh | bash
   ```
   
   **Alternative method** (download first, then run):
   ```sh
   wget https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh
   chmod +x install-minecraft-splitscreen.sh
   ./install-minecraft-splitscreen.sh
   ```
   
   **Note:** The installer will automatically detect which Java version you need based on your selected Minecraft version and install it if not present. No manual Java setup required!
   
   **Note:** If you already have PollyMC or PrismLauncher installed (via Flatpak or AppImage), the installer will detect and use your existing installation.

2. **Install Python 3 (optional)**
   - Only required if you want to add the launcher to Steam automatically
   - Most Linux distributions include Python 3 by default
   - For Arch: `sudo pacman -S python`
   - For Debian/Ubuntu: `sudo apt install python3`

3. **Follow the prompts** to customize your installation:
   - **Java installation:** The installer will automatically:
     - Detect the required Java version for your chosen Minecraft version (Java 8, 16, 17, or 21)
     - Search for existing Java installations on your system
     - Download and install the correct Java version automatically if not found (using [install-jdk-on-steam-deck](https://github.com/FlyingEwok/install-jdk-on-steam-deck))
     - Configure environment variables and validate the installation
   - **Minecraft version:** Choose your preferred version from a curated list of versions that are fully compatible with both required splitscreen mods (Controllable and Splitscreen Support), or press Enter for the latest compatible version
   - **Mod selection process:** The installer will automatically:
     - Search for compatible Fabric versions of all supported mods
     - Filter out incompatible versions using Modrinth and CurseForge APIs
     - Automatically resolve and download all mod dependencies using live API calls
     - Download dependency mods (like Fabric API for most mods) without manual specification
     - Handle mod conflicts and suggest alternatives when needed
     - Show progress for each mod download with success/failure status
     - Report any missing mods at the end if compatible versions aren't found
   - **Steam integration (optional):** 
     - Choose "y" to add a shortcut to Steam for easy access from Game Mode on Steam Deck
     - Choose "n" if you prefer to launch manually or don't use Steam
   - **Desktop launcher (optional):**
     - Choose "y" to create a desktop shortcut and add to your applications menu
     - Choose "n" if you only want to launch from Steam or manually
   - **Installation progress:** The installer will show detailed progress including:
     - PrismLauncher download and CLI verification
     - Instance creation (4 separate Minecraft instances for splitscreen)
     - PollyMC download and configuration
     - Automatic Java version detection and installation (if needed)
     - Mod downloads with Fabric compatibility verification
     - Automatic cleanup of temporary files

5. **Steam Deck only - Install Steam Deck controller auto-disable (required):**
   ```sh
   curl -sSL https://raw.githubusercontent.com/scawp/Steam-Deck.Auto-Disable-Steam-Controller/main/curl_install.sh | bash
   ```
   This automatically disables the built-in Steam Deck controller when external controllers are connected, which is essential for proper splitscreen controller counting. **This step is only needed on Steam Deck.**

## Technical Details
- **Mod Compatibility:** Uses both Modrinth and CurseForge APIs with Fabric filtering (`modLoaderType=4` for CurseForge, `.loaders[] == "fabric"` for Modrinth)
- **Instance Management:** Dynamic verification and registration of created instances
- **Error Recovery:** Enhanced error handling with automatic fallbacks and manual creation options
- **Memory Optimization:** Configured for splitscreen performance (3GB max, 512MB min per instance)

## Usage
- Launch the game from Steam, your desktop menu, or the generated desktop shortcut.
- The script will detect controllers and launch the correct number of Minecraft instances.
- On Steam Deck Game Mode, it will use a nested KDE session for best compatibility.
- **Steam Deck users:** For proper controller counting, you must disable the built-in Steam Deck controller when an external controller is connected. Use [Steam-Deck.Auto-Disable-Steam-Controller](https://github.com/scawp/Steam-Deck.Auto-Disable-Steam-Controller) to automate this process.

## Installation Locations

**AppImage installations:**
- **Primary installation:** `~/.local/share/PollyMC/` (instances, launcher, and game files)
- **Launcher script:** `~/.local/share/PollyMC/minecraftSplitscreen.sh` (auto-generated)

**Flatpak installations:**
- **Primary installation:** `~/.var/app/org.fn2006.PollyMC/data/PollyMC/`
- **Launcher script:** `~/.var/app/org.fn2006.PollyMC/data/PollyMC/minecraftSplitscreen.sh` (auto-generated)

**Note:** The launcher script is automatically generated during installation with the correct paths for your system. It includes version metadata for troubleshooting.

- **Temporary files:** Automatically cleaned up after successful installation

## Troubleshooting
- **Java installation issues:**
  - The installer automatically handles Java installation, but if issues occur:
  - Ensure you have an internet connection for downloading Java
  - For manual installation, the installer will provide specific instructions for your system
  - Steam Deck users can use the [install-jdk-on-steam-deck](https://github.com/FlyingEwok/install-jdk-on-steam-deck) script separately if needed
- **Controller issues:**
  - Make sure controllers are connected before launching.

## Updating

### Launcher Updates
To update the launcher script, simply re-run the installer. The script will be regenerated with the latest version and your existing settings will be preserved.

### Minecraft Version Updates
To update your Minecraft version or mod configuration, re-run the installer:
```sh
curl -fsSL https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh | bash
```
Select your new Minecraft version when prompted. The installer will:
   - Preserve your existing options.txt settings (keybindings, video settings, etc.)
   - Clear old mods and install fresh ones for the new version
   - Update the Fabric loader and all dependencies
   - Keep your existing player profiles and accounts
   - Preserve all your existing worlds

## Uninstall
- **AppImage installations:** Delete the PollyMC folder: `rm -rf ~/.local/share/PollyMC`
- **Flatpak installations:** Delete the PollyMC data: `rm -rf ~/.var/app/org.fn2006.PollyMC/data/PollyMC`
- Remove any desktop or Steam shortcuts you created.

## Credits
- Inspired by [ArnoldSmith86/minecraft-splitscreen](https://github.com/ArnoldSmith86/minecraft-splitscreen) (original concept/script, but this project is mostly a full rewrite).
- Additional contributions by [FlyingEwok](https://github.com/FlyingEwok) and others.
- Uses [PollyMC](https://github.com/fn2006/PollyMC) for gameplay and [PrismLauncher](https://github.com/PrismLauncher/PrismLauncher) for instance creation.
- Steam Deck Java installation script by [FlyingEwok](https://github.com/FlyingEwok/install-jdk-on-steam-deck) - provides seamless Java installation for Steam Deck's read-only filesystem with automatic version detection.
- Steam Deck controller auto-disable tool by [scawp](https://github.com/scawp/Steam-Deck.Auto-Disable-Steam-Controller) - automatically disables built-in Steam Deck controller when external controllers are connected, essential for proper splitscreen controller counting.

## Technical Improvements
- **Launcher Detection Module:** Automatically detects AppImage and Flatpak installations with appropriate path handling for each
- **Script Generation with Version Tracking:** Generated launcher scripts include version, commit hash, and generation timestamp
- **Dynamic Path Resolution:** No hardcoded paths - all paths are determined at install time based on detected launcher type
- **Complete Fabric Dependency Chain:** Ensures mods load and function correctly by including LWJGL 3, Minecraft, Intermediary Mappings, and Fabric Loader with proper dependency references
- **API Filtering:** Both Modrinth and CurseForge APIs are filtered to only download Fabric-compatible mod versions
- **Automatic Dependency Resolution:** Recursively resolves all mod dependencies using live API calls, eliminating the need to manually maintain dependency lists
- **Optimized Launcher Strategy:** Combines PrismLauncher's reliable CLI automation with PollyMC's offline-friendly gameplay approach
- **Smart Cleanup:** Automatically removes temporary build files and directories after successful setup
- **Enhanced Error Handling:** Multiple fallback mechanisms and retry strategies for robust installation

## TODO
- **Figure out a way to handle steam deck controller without needing to disable it for the whole system** - Find a method to selectively disable the Steam Deck controller only for splitscreen sessions while keeping it available for other games, and somehow figure out how to use Steam Deck controller with other controllers at the same time, as well as have the usecase with no Steam Deck controller at all and just the external controllers
- **Figure out preconfiguring controllers within controllable (if possible)** - Investigate automatic controller assignment configuration to avoid having Controllable grab the same controllers as all the other instances, ensuring each player gets their own dedicated controller

## Recent Improvements
- ✅ **Dynamic Splitscreen (v3.0.0)**: Players can join and leave mid-session - no need for everyone to start at the same time
- ✅ **Controller Hotplug**: Real-time detection of controller connections/disconnections
- ✅ **Automatic Window Repositioning**: Windows automatically resize when player count changes
- ✅ **Desktop Notifications**: Get notified when players join or leave
- ✅ **Auto-Generated Launcher Script**: The splitscreen launcher is now generated at install time with correct paths baked in - no more hardcoded paths
- ✅ **Flatpak Support**: Works with both Flatpak and AppImage installations of PollyMC and PrismLauncher
- ✅ **Smart Launcher Detection**: Automatically detects existing launcher installations and uses them instead of downloading new ones
- ✅ **Version Metadata**: Generated scripts include version, commit hash, and generation date for easier troubleshooting
- ✅ **Automatic Java Installation**: No manual Java setup required - the installer automatically detects, downloads, and installs the correct Java version for your chosen Minecraft version
- ✅ **Automatic Java Version Detection**: Automatically detects and uses the correct Java version for each Minecraft version (Java 8, 16, 17, or 21) with smart backward compatibility
- ✅ **Intelligent Version Selection**: Only Minecraft versions supported by both Controllable and Splitscreen Support mods are offered to users, ensuring full compatibility
- ✅ **Automatic Dependency Resolution**: No more hardcoded dependency lists - all mod dependencies are detected via API
- ✅ **Robust CurseForge Integration**: Full CurseForge API support with authentication and download URL resolution
- ✅ **Mixed Platform Support**: Seamlessly handles both Modrinth and CurseForge mods in the same installation
- ✅ **Smart Fallbacks**: Graceful degradation when APIs are unavailable



---
For more details, see the comments in the scripts or open an issue on the [GitHub repo](https://github.com/aradanmn/MinecraftSplitscreenSteamdeck).
