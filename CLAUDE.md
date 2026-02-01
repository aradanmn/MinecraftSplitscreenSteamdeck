# CLAUDE.md - AI Assistant Guide for MinecraftSplitscreenSteamdeck

This document provides essential context for AI assistants working on this codebase.

## Project Overview

**Minecraft Splitscreen Steam Deck & Linux Installer** - An automated installer for setting up splitscreen Minecraft (1-4 players) on Steam Deck and Linux systems.

**Version:** 2.1.0
**Repository:** https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
**License:** MIT

### Core Concept: Hybrid Launcher Approach

The project uses two launchers strategically:
- **PrismLauncher**: For CLI-based automated instance creation (has excellent CLI but requires Microsoft account)
- **PollyMC**: For gameplay (no license verification, offline-friendly)

After successful setup, PrismLauncher files are cleaned up, leaving only PollyMC for gameplay.

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
└── modules/                            # 14 specialized bash modules
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
    ├── pollymc_setup.sh                # PollyMC launcher setup
    ├── steam_integration.sh            # Steam library integration
    ├── desktop_launcher.sh             # Desktop .desktop file creation
    └── main_workflow.sh                # Main orchestration (~1300 lines)
```

## Key Architectural Concepts

### Path Configuration (CRITICAL)

`modules/path_configuration.sh` is the **single source of truth** for all paths. It manages two launcher configurations:

```bash
# CREATION launcher (PrismLauncher) - for CLI instance creation
CREATION_DATA_DIR, CREATION_INSTANCES_DIR, CREATION_EXECUTABLE

# ACTIVE launcher (PollyMC) - for gameplay
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
ACTIVE_*           # Related to gameplay launcher (PollyMC)
CREATION_*         # Related to instance creation launcher (PrismLauncher)
PRISM_*            # PrismLauncher-specific
POLLYMC_*          # PollyMC-specific
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
| GitHub API | PrismLauncher/PollyMC releases | No |

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
8. **Launcher Optimization** - PollyMC setup, PrismLauncher cleanup
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
- PollyMC data and AppImage (`~/.local/share/PollyMC`)
- PollyMC Flatpak data (`~/.var/app/org.fn2006.PollyMC`)
- PrismLauncher data and AppImage (`~/.local/share/PrismLauncher`)
- PrismLauncher Flatpak data (`~/.var/app/org.prismlauncher.PrismLauncher`)
- Flatpak applications (PollyMC, PrismLauncher)
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

**Note:** `modules/pollymc_setup.sh` was checked and contains no user prompts (contrary to original assumption)

---

### Issue #2: Steam Deck Controller Issues (MEDIUM PRIORITY)

**Problem A: No Controllers Detected**
When launching on Steam Deck without external controllers, the script detects the Steam virtual controller, filters it out, and then stops because no "real" controllers remain.

**Problem B: Double Button Presses in Desktop Mode**
When Steam is running in Desktop Mode, the Steam Deck's physical controls AND Steam's virtual controller BOTH send input to the game, causing every button press to register twice.

**Root Cause:** Steam Input creates virtual controller devices that mirror physical inputs. In Desktop Mode with Steam running:
- Physical controller → `/dev/input/js0` → game
- Steam virtual controller → `/dev/input/js1` → game (duplicate!)

**Current State:** The launcher script tries to filter Steam virtual controllers but:
1. Doesn't handle when virtual controller is the ONLY option
2. Doesn't prevent double-input when both physical AND virtual are active

**Solution Approaches:**

*For Problem A (no controllers):*
- If on Steam Deck AND only Steam virtual controller detected → allow using it as Player 1
- Provide "keyboard only" fallback mode

*For Problem B (double presses):*
1. **User-side fix:** Disable Steam Input per-game in Steam properties
2. **Script-side detection:** Warn user when both physical and virtual detected
3. **Script-side fix:** Before launching, advise user to either:
   - Launch from Game Mode (Steam handles this correctly there)
   - Disable Steam Input for Minecraft in Steam settings
   - Close Steam before launching (if not using Steam integration)

**Controllable Mod Note:** The Controllable mod has device selection settings. Users may be able to manually select only the physical controller there. Worth documenting.

**Files to modify:** `modules/launcher_script_generator.sh` (the generated script template)

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

### Issue #4: Minecraft New Versioning System (LOW PRIORITY - Future)
**Problem:** Minecraft is switching to a new version numbering system (announced at minecraft.net/en-us/article/minecraft-new-version-numbering-system).

**Current State:** Version parsing assumes `1.X.Y` format throughout codebase.

**Research Needed:**
- Fetch and document the new versioning scheme details
- Identify when this takes effect
- Likely format change from `1.21.x` to something like `25.1` (year-based?)

**Files likely affected:**
- `modules/version_management.sh` - version parsing and comparison
- `modules/java_management.sh` - Java version mapping
- `modules/lwjgl_management.sh` - LWJGL version mapping
- `modules/mod_management.sh` - mod compatibility matching

**Solution approach:**
- Create version parsing functions that handle both old and new formats
- Maintain backward compatibility for existing `1.x.x` versions
- Add detection for which format a version string uses

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
    "type": "pollymc",
    "install_type": "flatpak",
    "data_dir": "/home/deck/.var/app/org.fn2006.PollyMC/data/PollyMC"
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

### Implementation Order
1. ✅ **Issue #3 (Logging)** - DONE. All print_* functions auto-log.
2. ✅ **Issue #1 (User Input)** - DONE. All modules refactored to use `prompt_user()` and `prompt_yes_no()`.
3. ✅ **Issue #5 (Dynamic Splitscreen)** - DONE. Players can join/leave mid-session.
4. ⏳ **Issue #6 (Previous Installation Detection)** - Improves repeat user experience
5. ⏳ **Issue #2 (Controller Detection)** - Improves Steam Deck UX
6. ⏳ **Issue #4 (Versioning)** - Can wait until Minecraft actually releases new format

## Useful Debugging

```bash
# Check generated launcher script version
head -20 ~/.local/share/PollyMC/minecraftSplitscreen.sh

# View instance configuration
cat ~/.local/share/PollyMC/instances/latestUpdate-1/instance.cfg

# Check accounts
cat ~/.local/share/PollyMC/accounts.json | jq .
```
