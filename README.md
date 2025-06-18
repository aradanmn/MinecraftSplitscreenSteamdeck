# Minecraft Splitscreen Steam Deck & Linux Installer

This project provides an easy way to set up splitscreen Minecraft on Steam Deck and Linux using an optimized dual-launcher approach. It supports 1–4 players, controller detection, and seamless integration with Steam Game Mode and your desktop environment.

## Features
- **Optimized Installation:** Uses PrismLauncher for automated instance creation, then switches to PollyMC for gameplay
- Launch 1–4 Minecraft instances in splitscreen mode with proper Fabric support
- Automatic controller detection and per-player config
- Works on Steam Deck (Game Mode & Desktop Mode) and any Linux PC
- Optionally adds a launcher to Steam and your desktop menu
- Handles KDE/Plasma quirks for a clean splitscreen experience when running from Game Mode
- Self-updating launcher script
- **Fabric Loader:** Complete dependency chain implementation ensures mods load and function correctly
- **Automatic Dependency Resolution:** Uses live API calls to discover and install all mod dependencies without manual maintenance
- **Smart Cleanup:** Automatically removes temporary files and directories after successful setup

## Requirements
- **Java 21** (OpenJDK 21)
- Linux (Steam Deck or any modern distro)
- Internet connection for initial setup
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
- **Fabric compatibility verification:** All mods are filtered to ensure they're Fabric-compatible versions
- **Automatic dependency resolution:** Uses Modrinth and CurseForge APIs to automatically discover and install all required mod dependencies
- **Dependency chain validation:** Proper Fabric Loader setup with LWJGL 3, Intermediary Mappings, and all required dependencies
- **Fallback mechanisms:** Manual instance creation if CLI fails, with multiple retry strategies
- **Smart cleanup:** Automatically removes temporary PrismLauncher files after successful PollyMC setup

## Installation
1. **Install Java 21**
   - **For Steam Deck users (recommended):**
     ```sh
     # Download and run the Steam Deck JDK installer script
     wget https://raw.githubusercontent.com/BlackCorsair/install-jdk-on-steam-deck/master/scripts/install-jdk.sh
     chmod +x install-jdk.sh
     JDK_VERSION=21 ./install-jdk.sh
     ```
     This script will install Java 21 to `~/.local/jdk/` and is designed specifically for Steam Deck's read-only filesystem.
   
   - **For other Linux distributions:**
     - For Arch: `sudo pacman -S jdk21-openjdk`
     - For Debian/Ubuntu: `sudo apt install openjdk-21-jre`
     - Refer to your distro's documentation or package manager for other distributions.

2. **Install Python 3 (optional)**
   - Only required if you want to add the launcher to Steam automatically
   - Most Linux distributions include Python 3 by default
   - For Arch: `sudo pacman -S python`
   - For Debian/Ubuntu: `sudo apt install python3`

3. **Download and run the installer:**
   - You can get the latest installer script from the [Releases section](https://github.com/FlyingEwok/MinecraftSplitscreenSteamdeck/releases) (recommended for stable versions), or use the latest development version with:
   ```sh
   wget https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh
   chmod +x install-minecraft-splitscreen.sh
   ./install-minecraft-splitscreen.sh
   ```

4. **Follow the prompts** to customize your installation:
   - **Minecraft version:** Choose your preferred version or press Enter for the latest stable release (1.21.5 recommended for best mod compatibility)
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
- **Primary installation:** `~/.local/share/PollyMC/` (instances, launcher, and game files)
- **Temporary files:** Automatically cleaned up after successful installation
- **Launcher script:** `~/.local/share/PollyMC/minecraftSplitscreen.sh`

## Troubleshooting
- **Java 21 not found:**
  - Make sure you have Java 21 installed and available in your PATH.
  - See the error message for a link to this README.
- **Controller issues:**
  - Make sure controllers are connected before launching.

## Updating
The launcher script (`minecraftSplitscreen.sh`) will auto-update itself when a new version is available.

## Uninstall
- Delete the PollyMC folder: `rm -rf ~/.local/share/PollyMC`
- Remove any desktop or Steam shortcuts you created.

## Credits
- Inspired by [ArnoldSmith86/minecraft-splitscreen](https://github.com/ArnoldSmith86/minecraft-splitscreen) (original concept/script, but this project is mostly a full rewrite).
- Additional contributions by [FlyingEwok](https://github.com/FlyingEwok) and others.
- Uses [PollyMC](https://github.com/fn2006/PollyMC) for gameplay and [PrismLauncher](https://github.com/PrismLauncher/PrismLauncher) for instance creation.
- Steam Deck Java installation script by [BlackCorsair](https://github.com/BlackCorsair/install-jdk-on-steam-deck) - provides seamless Java 21 installation for Steam Deck's read-only filesystem.
- Steam Deck controller auto-disable tool by [scawp](https://github.com/scawp/Steam-Deck.Auto-Disable-Steam-Controller) - automatically disables built-in Steam Deck controller when external controllers are connected, essential for proper splitscreen controller counting.

## Technical Improvements
- **Complete Fabric Dependency Chain:** Ensures mods load and function correctly by including LWJGL 3, Minecraft, Intermediary Mappings, and Fabric Loader with proper dependency references
- **API Filtering:** Both Modrinth and CurseForge APIs are filtered to only download Fabric-compatible mod versions
- **Automatic Dependency Resolution:** Recursively resolves all mod dependencies using live API calls, eliminating the need to manually maintain dependency lists
- **Optimized Launcher Strategy:** Combines PrismLauncher's reliable CLI automation with PollyMC's offline-friendly gameplay approach
- **Smart Cleanup:** Automatically removes temporary build files and directories after successful setup
- **Enhanced Error Handling:** Multiple fallback mechanisms and retry strategies for robust installation

## TODO
- Check Controllable, Framework, and Splitscreen Support mods' supported Minecraft versions and only let users select from those versions of Minecraft to ensure compatibility

## Recent Improvements
- ✅ **Automatic Dependency Resolution**: No more hardcoded dependency lists - all mod dependencies are detected via API
- ✅ **Robust CurseForge Integration**: Full CurseForge API support with authentication and download URL resolution
- ✅ **Mixed Platform Support**: Seamlessly handles both Modrinth and CurseForge mods in the same installation
- ✅ **Smart Fallbacks**: Graceful degradation when APIs are unavailable

---
For more details, see the comments in the scripts or open an issue on the [GitHub repo](https://github.com/FlyingEwok/MinecraftSplitscreenSteamdeck).
