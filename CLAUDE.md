# CLAUDE.md - AI Assistant Guide for MinecraftSplitscreenSteamdeck

This document provides essential context for AI assistants working on this codebase.

## Session Start Checklist (do this first, every session)

1. **Sync with remote:**
   ```bash
   git fetch origin && git pull --ff-only origin main
   ```

2. **Read session memory** — `.claude/memory/MEMORY.md` is the index; read it first,
   then read any linked files relevant to the current task. These files record decisions,
   bugs fixed, architectural context, and open issues accumulated across all past sessions.
   They are the fastest way to get up to speed on what has already been done and why.

## Project Overview

**Minecraft Splitscreen Steam Deck & Linux Installer** - An automated installer for setting up splitscreen Minecraft (1-4 players) on Steam Deck and Linux systems.

**Version:** 3.0.0
**Repository:** https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
**License:** MIT

### Core Concept: PrismLauncher-Only Architecture

PrismLauncher handles everything — both automated CLI-based instance creation and gameplay. A Microsoft account is required. There is no longer a second launcher involved.

## Repository Structure

```
/
├── install-minecraft-splitscreen.sh    # Main entry point (386 lines)
├── cleanup-minecraft-splitscreen.sh    # Uninstaller script (removes all components)
├── add-to-steam.py                     # Python script for Steam integration
├── accounts.json                       # Pre-configured offline accounts (P1-P4)
├── token.enc                           # Encrypted CurseForge API token
├── README.md                           # User documentation
├── .github/workflows/release.yml       # GitHub Actions release workflow
└── modules/                            # 13 specialized bash modules
    ├── version_info.sh                 # Version constants
    ├── utilities.sh                    # Print functions, system detection
    ├── path_configuration.sh           # CRITICAL: Centralized path management
    ├── launcher_setup.sh               # PrismLauncher detection/installation
    ├── launcher_script_generator.sh    # Generates minecraftSplitscreen.sh
    ├── java_management.sh              # Java auto-detection/installation
    ├── version_management.sh           # Minecraft version selection
    ├── lwjgl_management.sh             # LWJGL version detection
    ├── mod_management.sh               # Mod compatibility (largest module, ~1900 lines)
    ├── instance_creation.sh            # Creates 4 Minecraft instances
    ├── steam_integration.sh            # Steam library integration
    ├── desktop_launcher.sh             # Desktop .desktop file creation
    └── main_workflow.sh                # Main orchestration (~1300 lines)
```

## Key Architectural Concepts

### Path Configuration (CRITICAL)

`modules/path_configuration.sh` is the **single source of truth** for all paths. It manages the PrismLauncher configuration:

```bash
# CREATION launcher (PrismLauncher) - for CLI instance creation
CREATION_DATA_DIR, CREATION_INSTANCES_DIR, CREATION_EXECUTABLE

# ACTIVE launcher (PrismLauncher) - for gameplay
ACTIVE_DATA_DIR, ACTIVE_INSTANCES_DIR, ACTIVE_EXECUTABLE, ACTIVE_LAUNCHER_SCRIPT
```

**Never hardcode paths.** Always use these variables.

### Module Loading Order

Modules are sourced in dependency order in `install-minecraft-splitscreen.sh`:
1. version_info.sh
2. utilities.sh
3. path_configuration.sh (must be early - other modules depend on it)
4. All other modules...
5. main_workflow.sh (last - orchestrates everything)

### Variable Naming Conventions

```bash
UPPERCASE          # Global constants and exported variables
lowercase          # Local variables and functions
ACTIVE_*           # Related to gameplay launcher (PrismLauncher)
CREATION_*         # Related to instance creation launcher (PrismLauncher)
PRISM_*            # PrismLauncher-specific
```

### Function Naming Patterns

```bash
check_*()          # Validation functions
detect_*()         # Detection/discovery functions
setup_*()          # Setup/configuration functions
get_*()            # Getter functions (return values)
handle_*()         # Error/event handlers
download_*()       # Download operations
install_*()        # Installation functions
create_*()         # Creation functions
cleanup_*()        # Cleanup functions
```

## Code Conventions

### Bash Standards

```bash
set -euo pipefail  # Always at script start (exit on error, undefined vars, pipe failures)
readonly VAR       # For immutable constants
local var          # For function-scoped variables
[[ ]]              # For conditionals (not [ ])
$()                # For command substitution (not backticks)
```

### Documentation Standard (JSDoc-style)

All modules use this header format:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2034  # (if needed)
#
# @file module_name.sh
# @version X.Y.Z
# @date YYYY-MM-DD
# @author Author Name
# @license MIT
# @repository https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
# Brief description of module purpose.
#
# @dependencies
# - dependency1
# - dependency2
#
# @exports
# - VARIABLE1
# - function1()
```

### Versioning Convention (IMPORTANT)

**When modifying any module file, you MUST update its version number and changelog.**

Version format: `Major.Minor.Patch` (e.g., `2.1.0`)

| Component | When to Increment | Example |
|-----------|-------------------|---------|
| **Major** | Breaking changes, complete rewrites, new major release | 1.x.x → 2.0.0 |
| **Minor** | New features, significant improvements | 2.0.x → 2.1.0 |
| **Patch** | Bug fixes, small changes | 2.1.0 → 2.1.1 |

**Version history:**
- `1.x.x` = Original flyingEwok era
- `2.x.x` = aradanmn fork (current)
- `3.x.x` = Reserved for future major release (e.g., dynamic splitscreen)

**Update checklist when modifying a file:**
1. Increment `@version` tag appropriately
2. Update `@date` to current date
3. Add changelog entry with version, date, and description:
   ```bash
   # @changelog
   #   2.1.1 (2026-01-31) - Fix: Description of the bug fix
   #   2.1.0 (2026-01-30) - Added new feature X
   ```

**Global version:** `SCRIPT_VERSION` in `version_info.sh` should match the highest module version for releases.

### Print Functions (from utilities.sh)

```bash
print_header "Section Title"     # Blue header with borders
print_success "Success message"  # Green with checkmark
print_warning "Warning message"  # Yellow with warning symbol
print_error "Error message"      # Red with X
print_info "Info message"        # Cyan with info symbol
print_progress "Progress..."     # Progress indicator
```

### Error Handling Pattern

```bash
# Non-fatal errors with fallback
if ! some_operation; then
    print_warning "Operation failed, trying fallback..."
    fallback_operation || {
        print_error "Fallback also failed"
        return 1
    }
fi
```

## External APIs Used

| API | Purpose | Auth Required |
|-----|---------|---------------|
| Modrinth API | Mod versions, compatibility | No |
| CurseForge API | Alternative mod source | Yes (token.enc) |
| Fabric Meta API | Fabric Loader, LWJGL versions | No |
| Mojang API | Minecraft versions, Java requirements | No |
| SteamGridDB API | Custom artwork | No |
| GitHub API | PrismLauncher releases | No |

## Development Commands

### Running the Installer

```bash
# Local development (uses git remote to detect repo)
./install-minecraft-splitscreen.sh

# With custom source URL
INSTALLER_SOURCE_URL="https://raw.githubusercontent.com/USER/REPO/BRANCH/install-minecraft-splitscreen.sh" \
    ./install-minecraft-splitscreen.sh

# Via curl (production)
curl -fsSL https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh | bash
```

### Testing Modules Individually

Modules can't run standalone - they're sourced by the main script. For testing:

```bash
# Source dependencies manually for testing
source modules/version_info.sh
source modules/utilities.sh
source modules/path_configuration.sh
# ... then source your module
```

### Release Process

Releases are automated via GitHub Actions (`.github/workflows/release.yml`):
1. Create a tag: `git tag v2.0.1`
2. Push the tag: `git push origin v2.0.1`
3. GitHub Actions creates the release automatically

## Common Development Tasks

### Adding a New Mod

1. Edit `modules/mod_management.sh`
2. Add to the `MODS` array with format: `"ModName|platform|project_id|required|dependencies"`
3. Platform: `modrinth` or `curseforge`
4. Dependencies are auto-resolved via API

### Adding a New Module

1. Create `modules/new_module.sh` with JSDoc header
2. Add to the sourcing list in `install-minecraft-splitscreen.sh` (respect dependency order)
3. Export functions/variables clearly in the header

### Modifying Path Logic

**Always edit `modules/path_configuration.sh`** - never add path logic elsewhere.

### Supporting a New Immutable OS

Edit `modules/utilities.sh`:

```bash
is_immutable_os() {
    # Add detection for new OS
    [[ -f /etc/new-os-release ]] && return 0
    # ... existing checks
}
```

## Important Implementation Details

### Java Version Mapping

In `modules/java_management.sh`:
- Minecraft 1.21+ → Java 21
- Minecraft 1.18-1.20 → Java 17
- Minecraft 1.17 → Java 16
- Minecraft 1.13-1.16 → Java 8

### LWJGL Version Mapping

In `modules/lwjgl_management.sh`:
- Minecraft 1.21+ → LWJGL 3.3.3
- Minecraft 1.19-1.20 → LWJGL 3.3.1
- Minecraft 1.18 → LWJGL 3.2.2
- etc.

### Instance Naming

Instances are named: `latestUpdate-1`, `latestUpdate-2`, `latestUpdate-3`, `latestUpdate-4`

### Generated Files

The installer generates `minecraftSplitscreen.sh` at runtime with:
- Correct paths baked in
- Version metadata (SCRIPT_VERSION, COMMIT_HASH, GENERATION_DATE)
- Controller detection logic
- Steam Deck Game Mode handling

## Pitfalls to Avoid

1. **Never hardcode paths** - Always use path_configuration.sh variables
2. **Don't assume launcher type** - Always check both Flatpak and AppImage
3. **Don't skip API fallbacks** - Always have hardcoded fallback mappings
4. **Module order matters** - path_configuration.sh must load before modules that use paths
5. **Signal handling** - Ctrl+C cleanup is handled in main script; don't override
6. **Account merging** - Always preserve existing Microsoft accounts when adding offline accounts

## Git Workflow

- **Main branch:** `main` (stable releases)
- **Development:** Feature branches
- **Commit style:** Conventional commits (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`)

## Key Files Quick Reference

| File | Lines | Purpose |
|------|-------|---------|
| `install-minecraft-splitscreen.sh` | ~386 | Entry point, module loader |
| `cleanup-minecraft-splitscreen.sh` | ~490 | Uninstaller (removes all components) |
| `modules/path_configuration.sh` | ~600+ | Path management (CRITICAL) |
| `modules/mod_management.sh` | ~1900 | Mod compatibility (largest) |
| `modules/main_workflow.sh` | ~1300 | Main orchestration |
| `modules/instance_creation.sh` | ~600+ | Instance creation logic |
| `add-to-steam.py` | ~195 | Steam integration |


## Installation Flow (10 Phases)

1. **Workspace Setup** - Temporary directories, signal handling
2. **Core Setup** - Java, PrismLauncher, CLI verification
3. **Version Detection** - Minecraft, Fabric, LWJGL versions
4. **Account Setup** - Offline player accounts (P1-P4)
5. **Mod Compatibility** - API checking for compatible versions
6. **User Selection** - Interactive mod choice
7. **Instance Creation** - 4 splitscreen instances
8. **Launcher Script Generation** - Generate minecraftSplitscreen.sh with correct paths
9. **System Integration** - Steam, desktop shortcuts
10. **Completion Report** - Summary with paths and usage

## Cleanup Script

The `cleanup-minecraft-splitscreen.sh` script removes all components installed by the installer:

```bash
# Preview what would be removed (dry-run mode)
./cleanup-minecraft-splitscreen.sh --dry-run

# Clean everything except Java (default)
./cleanup-minecraft-splitscreen.sh

# Clean everything including Java, no prompts
./cleanup-minecraft-splitscreen.sh --remove-java --force

# Remote cleanup via SSH
ssh deck@steamdeck './cleanup-minecraft-splitscreen.sh --force'
```

**What it removes:**
- PrismLauncher data and AppImage (`~/.local/share/PrismLauncher`)
- PrismLauncher Flatpak data (`~/.var/app/org.prismlauncher.PrismLauncher`)
- PrismLauncher Flatpak application
- Desktop shortcuts and app menu entries
- Installer logs (`~/.local/share/MinecraftSplitscreen`)

**What it preserves by default:**
- Java installations (`~/.local/jdk/`) - use `--remove-java` to delete

**Note:** Steam shortcuts (non-Steam games) must be removed manually in Steam.

## Known Issues

### SSH + curl | bash Causes Script Crash

**Problem:** When running the installer via `curl | bash` over SSH, the script crashes at interactive prompts (exit code 139/SIGSEGV).

**Root Cause:** The `prompt_user` function tries to read from `/dev/tty` for `curl | bash` compatibility, but this fails in certain SSH configurations.

**Workaround:** Download the script first, then run it directly:

```bash
# Instead of: curl -fsSL URL | bash

# Do this:
curl -fsSL https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh -o /tmp/install.sh
chmod +x /tmp/install.sh
INSTALLER_SOURCE_URL=https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh /tmp/install.sh
```

**Status:** Affects remote SSH testing. Local execution works fine.

## TODO Items (from README)

1. Steam Deck controller handling without system-wide disable
2. Pre-configuring controllers within Controllable mod

## Active Development Backlog

### Issue #1: Centralized User Input Handling for curl | bash Mode ✅ IMPLEMENTED
**Problem:** When running via `curl | bash`, stdin is consumed by the script download, breaking interactive prompts. The PollyMC Flatpak detection on SteamOS prompts for user choice but can't receive input.

**Solution Implemented:**
- **Utility functions in `utilities.sh`:**
  - `prompt_user(prompt, default, timeout)` - Works with curl | bash by reopening /dev/tty
  - `prompt_yes_no(question, default)` - Simplified yes/no prompts with automatic logging

**Modules Refactored:**
- `modules/version_management.sh` - Minecraft version selection (2 prompts)
- `modules/mod_management.sh` - Mod selection prompt
- `modules/steam_integration.sh` - "Add to Steam?" prompt (now uses `prompt_yes_no`)
- `modules/desktop_launcher.sh` - "Create desktop launcher?" prompt (now uses `prompt_yes_no`)

**Note:** `modules/pollymc_setup.sh` has since been removed (PollyMC is dead as of 2026-02-07).

---

### Issue #2: Steam Deck Controller Issues ✅ RESOLVED

**Problem A (No Controllers): FIXED**
- `getControllerCount()` uses uhid-based filtering to separate real from virtual devices
- Steam Deck built-in controls: if count=0 and `hasSteamVirtualController()` → P1 using built-in
- `promptControllerMode()` provides keyboard/mouse fallback when no controllers at all

**Problem B (Double Input): FIXED**
- uhid-based device counting already filters Steam Input virtual duplicates
- Fallback halving logic (`(count + 1) / 2`) for older kernels where uhid filtering isn't available
- `HANDHELD_MODE=1` bypasses counting entirely, always reports exactly 1 controller

**Key functions in generated launcher (`launcher_script_generator.sh`):**
- `hasSteamVirtualController()` — detects Steam virtual gamepad presence
- `getControllerCount()` — uhid-filtered count with Steam Deck built-in fallback
- `hasKeyboardInput()` — keyboard/mouse detection
- `promptControllerMode()` — interactive fallback when no controllers found

---

### Issue #3: Logging System ✅ IMPLEMENTED
**Problem:** Debugging issues across multiple machines (Bazzite, SteamOS, etc.) is difficult without logs.

**Solution Implemented:**
- **Log location:** `~/.local/share/MinecraftSplitscreen/logs/`
- **Installer log:** `install-YYYY-MM-DD-HHMMSS.log`
- **Launcher log:** `launcher-YYYY-MM-DD-HHMMSS.log`
- Auto-rotation: keeps last 10 logs per type
- System info logged at startup (OS, kernel, environment, tools)

**Key Design Decision:** Print functions auto-log (no separate log calls needed)
- `print_success()`, `print_error()`, etc. all automatically write to log
- `log()` is for debug-only info that shouldn't clutter terminal
- Cleaner code with no duplicate logging statements

**Files modified:**
- `modules/utilities.sh` - logging infrastructure, print_* auto-log
- `modules/main_workflow.sh` - init_logging() call, log file display
- `modules/launcher_script_generator.sh` - log_info/log_error/log_warning in generated script

---

### Issue #4: Minecraft New Versioning System ✅ RESOLVED

**Resolution:** Year-based versioning (`YY.X` / `YY.X.Y`) is fully supported.

**Implemented in `modules/utilities.sh`:**
- `detect_version_format()` — returns `"legacy"` or `"year"`
- `get_version_series()` — extracts major.minor from either format (`1.21.3` → `1.21`, `25.1.2` → `25.1`)
- `normalize_version()` — treats year-based versions as newer than legacy

**Modules updated to use these utilities:**
- `modules/lwjgl_management.sh` — `get_lwjgl_version_by_mapping()` handles both formats
- `modules/mod_management.sh` — version matching uses `get_version_series()`

---

### Issue #5: Dynamic Splitscreen Mode (v3.0.0) ✅ CODE COMPLETE - NEEDS TESTING
**Feature:** Players can join and leave mid-session without coordinating start times.

**Status:** All code implemented in `launcher_script_generator.sh`. Ready for real-world testing.

**CLI Arguments (v3.0.1):**
```bash
minecraftSplitscreen.sh                  # Interactive mode selection
minecraftSplitscreen.sh --mode=static    # Skip prompt, use static mode
minecraftSplitscreen.sh --mode=dynamic   # Skip prompt, use dynamic mode
minecraftSplitscreen.sh --help           # Show usage information
```

**Technical Implementation:**
- Controller monitoring via `inotifywait` with polling fallback (lines 554-632)
- Process tracking with PID arrays for 4 instance slots (lines 635-712)
- External window repositioning via `xdotool`/`wmctrl` on X11 (lines 715-943)
- Instance restart fallback for Game Mode (gamescope)
- Event loop architecture with join/leave handlers (lines 946-1083)
- Mode selection UI (static vs dynamic) at launch (lines 1217-1235)
- CLI argument parsing for non-interactive use (lines 1205-1280)
- Zero-controller handling merged from rev2 (promptControllerMode)

**Key Functions in Generated Launcher:**
- `runDynamicSplitscreen()` - Main event loop
- `runStaticSplitscreen()` - Original behavior (with rev2 fixes)
- `startControllerMonitor()` / `stopControllerMonitor()` - IPC via named pipes
- `handleControllerChange()` - Add/remove players
- `repositionAllWindows()` - Adjust layout when player count changes
- `launchInstanceForSlot()` / `stopInstance()` - Instance lifecycle

**Files modified:**
- `modules/launcher_script_generator.sh` - Major rewrite (~1300 lines, dynamic mode logic)
- `modules/utilities.sh` - `check_dynamic_mode_dependencies()`, `show_dynamic_mode_install_hints()`
- `modules/version_info.sh` - Version bump to 3.0.0
- All module headers - Version update to 3.0.0
- `README.md` - Feature documentation

**Optional dependencies for best experience:**
- `inotify-tools` - Efficient controller hotplug detection (without: 2-second polling)
- `xdotool`/`wmctrl` - Smooth window repositioning on X11 (without: instances restart)
- `libnotify` - Desktop notifications when players join/leave (without: silent)

**Testing Checklist (Not Yet Done):**
- [ ] Steam Deck Game Mode with dynamic player join/leave
- [ ] Steam Deck Desktop Mode with X11 window repositioning
- [ ] Linux desktop with inotifywait hotplug detection
- [ ] Fallback behavior without optional tools
- [ ] Mode selection timeout defaults correctly
- [ ] CLI arguments: `--mode=static`, `--mode=dynamic`, `--help`
- [ ] Installer completion summary shows dependency status

---

### Issue #6: Detect Previous Installation (MEDIUM PRIORITY)
**Problem:** When users run the installer multiple times, it starts fresh each time without recognizing existing installations. Users may want to update mods, change Minecraft version, or modify their setup without full reinstallation.

**Desired Behavior:**
- Detect if splitscreen instances already exist (check for `latestUpdate-1` through `latestUpdate-4`)
- Detect existing launcher script (`minecraftSplitscreen.sh`)
- If previous installation found, prompt user with options:
  1. **Update** - Keep same Minecraft version, update mods to latest compatible
  2. **Change Version** - Select new Minecraft version, reinstall mods
  3. **Reconfigure** - Change mod selection (add/remove mods)
  4. **Fresh Install** - Delete existing and start over
  5. **Cancel** - Exit without changes

**Detection Method: Config File**
Save installation config to: `~/.local/share/MinecraftSplitscreen/install-config.json`

```json
{
  "version": "3.0.0",
  "installed_at": "2026-01-31T19:18:01Z",
  "updated_at": "2026-01-31T19:18:01Z",
  "minecraft_version": "1.21.4",
  "fabric_version": "0.16.10",
  "launcher": {
    "type": "prismlauncher",
    "install_type": "flatpak",
    "data_dir": "/home/deck/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher"
  },
  "mods": {
    "selected": ["fabric-api", "controllable", "worldhost", "cloth-config"],
    "versions": {
      "fabric-api": "0.92.1",
      "controllable": "1.2.3"
    }
  },
  "instances": ["latestUpdate-1", "latestUpdate-2", "latestUpdate-3", "latestUpdate-4"],
  "options": {
    "steam_integration": true,
    "desktop_shortcut": true,
    "dynamic_mode_available": true
  }
}
```

**Benefits:**
- Single file to check for previous installation
- Contains all selections without parsing instance files
- Easy to read/write with `jq`
- Version field allows migration if format changes
- `updated_at` tracks when last modified

**Files to modify:**
- `modules/main_workflow.sh` - Add detection at start of `run_installation()`
- `modules/utilities.sh` - Add `detect_existing_installation()` and `save_install_config()` functions
- Potentially new module: `modules/update_management.sh` for update logic

**Considerations:**
- Preserve user's Microsoft account if they added one
- Preserve any custom JVM arguments
- Handle partial installations gracefully (config exists but instances missing)
- Log what was detected and what action was taken
- Use `jq` for JSON parsing (already a dependency)

---

### Issue #7: PollyMC Removed ✅ RESOLVED

**Resolution:** PollyMC code removed. PrismLauncher is now the sole launcher. Users require a Microsoft account. `pollymc_setup.sh` deleted.

PollyMC went offline as of 2026-02-07 (`pollymc.org` does not resolve, GitHub repo `fn2006/PollyMC` returns 404). All PollyMC references have been removed from the codebase and documentation.

---

### Issue #8: Microsoft Account Setup During Installation (MEDIUM PRIORITY)
**Problem:** After installation, users must manually open PrismLauncher GUI and log into their Microsoft account before Minecraft can launch. This is a poor UX especially on Steam Deck where switching to Desktop Mode is required.

**Desired Behavior:** During installation, prompt the user to authenticate their Microsoft account via OAuth device code flow (open URL + enter code), so the account is ready when installation completes.

**Research Needed:**
- PrismLauncher account storage format (`accounts.json`)
- Microsoft OAuth device code flow for Minecraft Java Edition
- Token format needed by PrismLauncher (Xbox Live → XSTS → Minecraft tokens)
- Whether tokens can be injected into PrismLauncher's accounts.json

**Solution Approach:**
- Implement OAuth device code flow: user visits `microsoft.com/devicelogin` and enters a code
- Exchange tokens: MS Auth → Xbox Live → XSTS → Minecraft
- Write valid token data to PrismLauncher's `accounts.json`
- Works over SSH/headless since it only needs a browser on any device

**Files to modify:**
- `modules/main_workflow.sh` - Add account setup phase
- New utility functions in `modules/utilities.sh` or new module `modules/account_setup.sh`

---

### Issue #9: Controller-to-Session Mapping ✅ RESOLVED

**Root cause discovered:** Controllable stores controller selection in `selected_controllers.json` using SDL2 GUIDs. The saved GUIDs were from a Steam session (Steam Virtual Gamepad, vendor=0x28DE) but Controllable's own bundled SDL2 (at `controllable_natives/SDL/2.32.10/libSDL2.so`) sees raw Bluetooth Sony controllers (vendor=0x054c). This GUID mismatch caused Controllable to fall back to `autoSelect=true` and always grab controller index 0 for every instance.

**Fix implemented in `launcher_script_generator.sh` v3.1.0:**
- `findControllableSDL2()` — locates Controllable's bundled `libSDL2.so`
- `enumerateControllerGUIDs()` — Python3/ctypes enumerate using the same SDL2 Controllable uses
- `writeControllableConfig()` — writes correct `selected_controllers.json` for a slot
- `setControllableAutoSelect()` — disables/enables `autoSelect` in `controllable-client.toml`
- `assignControllerToSlot()` — called by `launchInstanceForSlot()`: finds unassigned GUID, writes config, disables autoSelect on active instances
- `markInstanceStopped()` — clears GUID assignment and re-enables autoSelect on stop

**Known limitation:** Identical controller models (e.g., 3x DS4 v2) share the same SDL2 GUID. SDL2 has no device-level isolation so it always resolves to the first physical match. Players with all-same-model controllers may still get mixed assignments; mixed controller sets (different models) work correctly.

---

### Issue #10: Require Controller Disconnect+Reconnect Before Relaunch (HIGH PRIORITY)

**Problem:** If a player quits Minecraft but leaves their controller connected, the dynamic mode may relaunch a new session for that slot automatically. The controller count hasn't changed so no CONTROLLER_CHANGE event fires — but a timing race between `checkForExitedInstances()` (which decrements active count) and a subsequent controller event can cause `handleControllerChange()` to see `controller_count > active_instances` and relaunch.

**Desired Behavior:** Once a controller has been used in a session, it must be physically disconnected and reconnected before it can trigger a new session launch. This gives players intentional control over when they re-join.

**Implementation Approach:**
- Track a `CONTROLLER_SEEN` set of device paths that have participated in the current session
- In `monitorControllers()` (using inotifywait), only emit a `CONTROLLER_CHANGE` event on a `create` event for a device that was previously deleted — not for devices that were present throughout
- In polling fallback: track which js indices were active and require a disappear→reappear cycle before counting as "new"
- Add `INSTANCE_CONTROLLER_DEV[$idx]` to track which device was assigned to each slot

**Files to modify:** `modules/launcher_script_generator.sh` — `monitorControllers()`, `handleControllerChange()`, `markInstanceStopped()`

---

### Issue #11: Black Placeholder Window for 3-Player Layout ✅ RESOLVED

**Problem:** In a 3-player session, the layout is a 2×2 grid with the bottom-right quadrant (P4 position) empty. This leaves an ugly gap — the desktop/wallpaper is visible there.

**Desired Behavior:**
- When exactly 3 players are active: show a solid black window filling the P4 (bottom-right) quadrant
- When a 4th player joins: close the black window
- When player count drops to 2 or below: close the black window (layout switches to halves)

**Implementation:** python3+GTK (PyGObject/gi) primary — undecorated black GTK window, KWin script positions it into P4 quadrant. yad (no --css), zenity, tkinter as fallbacks. Confirmed working in Desktop Mode 2026-04-18.

**Note:** `yad --css` is NOT a valid flag in yad 9.3 (Bazzite) — causes silent crash. Always use python3+gi as primary.

**Files modified:** `modules/launcher_script_generator.sh` v3.2.15 — `showPlaceholderWindow()`, `hidePlaceholderWindow()`, `updatePlaceholderWindow()`

---

### Implementation Order
1. ✅ **Issue #3 (Logging)** - DONE. All print_* functions auto-log.
2. ✅ **Issue #1 (User Input)** - DONE. All modules refactored to use `prompt_user()` and `prompt_yes_no()`.
3. ✅ **Issue #5 (Dynamic Splitscreen)** - DONE. Players can join/leave mid-session.
4. ✅ **Issue #7 (PollyMC Removed)** - DONE. PollyMC code removed, PrismLauncher-only.
5. ⏳ **Issue #8 (MS Account During Install)** - OAuth device flow for headless auth
6. ⏳ **Issue #6 (Previous Installation Detection)** - Improves repeat user experience
7. ✅ **Issue #2 (Controller Detection)** - DONE. uhid filtering, Steam Deck built-in fallback, keyboard mode.
8. ✅ **Issue #4 (Versioning)** - DONE. Year-based format handled via utilities.sh version utilities.
9. ✅ **Issue #9 (Controller-to-Session Mapping)** - DONE. Uses Controllable's own SDL2 to write correct GUIDs; disables autoSelect on active slots.
10. ⏳ **Issue #10 (Disconnect+Reconnect Before Relaunch)** - Prevent unintended relaunch when controller stays connected
11. ✅ **Issue #11 (3-Player Placeholder Window)** - Black window fills P4 gap when 3 players active

## Useful Debugging

```bash
# Check generated launcher script version
head -20 ~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/minecraftSplitscreen.sh

# View instance configuration
cat ~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances/latestUpdate-1/instance.cfg

# Check accounts
cat ~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/accounts.json | jq .

# AppImage paths (if not using Flatpak)
# ~/.local/share/PrismLauncher/minecraftSplitscreen.sh
# ~/.local/share/PrismLauncher/instances/latestUpdate-1/instance.cfg
```
