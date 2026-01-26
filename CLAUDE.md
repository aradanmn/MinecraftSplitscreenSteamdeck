# CLAUDE.md - AI Assistant Guide for MinecraftSplitscreenSteamdeck

This document provides essential context for AI assistants working on this codebase.

## Project Overview

**Minecraft Splitscreen Steam Deck & Linux Installer** - An automated installer for setting up splitscreen Minecraft (1-4 players) on Steam Deck and Linux systems.

**Version:** 2.0.0
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

## TODO Items (from README)

1. Steam Deck controller handling without system-wide disable
2. Pre-configuring controllers within Controllable mod

## Active Development Backlog

### Issue #1: Centralized User Input Handling for curl | bash Mode (HIGH PRIORITY)
**Problem:** When running via `curl | bash`, stdin is consumed by the script download, breaking interactive prompts. The PollyMC Flatpak detection on SteamOS prompts for user choice but can't receive input.

**Current State:** Some input handling exists scattered across modules, but it's inconsistent.

**Solution:** Create a centralized `prompt_user()` function in `utilities.sh` that:
- Detects if stdin is available (TTY check)
- If not available, reopens `/dev/tty` for user input
- Provides consistent timeout and default value handling
- All modules should use this single function for any user prompts

**Files to modify:** `modules/utilities.sh`, then refactor all modules that prompt users

**Pattern to implement:**
```bash
prompt_user() {
    local prompt="$1"
    local default="$2"
    local timeout="${3:-30}"
    local response

    # Reopen tty if stdin is not a terminal (curl | bash case)
    if [[ ! -t 0 ]]; then
        exec < /dev/tty || { echo "$default"; return; }
    fi

    read -t "$timeout" -p "$prompt" response || response="$default"
    echo "${response:-$default}"
}
```

---

### Issue #2: Steam Deck Virtual Controller Detection (MEDIUM PRIORITY)
**Problem:** When launching on Steam Deck without external controllers, the script detects the Steam virtual controller, filters it out, and then stops because no "real" controllers remain.

**Current State:** The launcher script correctly filters Steam virtual controllers but doesn't handle the case where that's the ONLY controller available.

**Solution:** Modify controller detection logic to:
- If on Steam Deck AND only Steam virtual controller detected AND no external controllers → allow using Steam Deck as Player 1
- Provide a fallback "keyboard only" mode or prompt user
- Consider: Steam Deck's built-in controls should count as 1 player

**Files to modify:** `modules/launcher_script_generator.sh` (the generated script template)

---

### Issue #3: Logging System (MEDIUM PRIORITY)
**Problem:** Debugging issues across multiple machines (Bazzite, SteamOS, etc.) is difficult without logs. User must set up dev environment on each machine.

**Current State:** No persistent logging - output only goes to terminal.

**Solution:** Implement logging in both installer and launcher:
- **Log location:** `~/.local/share/MinecraftSplitscreen/logs/`
- **Installer log:** `install-YYYY-MM-DD-HHMMSS.log`
- **Launcher log:** `launcher-YYYY-MM-DD-HHMMSS.log`
- Keep last N logs (e.g., 10) to prevent disk fill
- Log should include: timestamp, system info, all operations, errors, and final status
- Add `log()` function to utilities.sh that both prints and logs

**Files to modify:**
- `modules/utilities.sh` - add logging functions
- `modules/main_workflow.sh` - initialize logging
- `modules/launcher_script_generator.sh` - add logging to generated script

**Pattern to implement:**
```bash
LOG_FILE=""
init_logging() {
    local log_dir="$HOME/.local/share/MinecraftSplitscreen/logs"
    mkdir -p "$log_dir"
    LOG_FILE="$log_dir/install-$(date +%Y-%m-%d-%H%M%S).log"
    # Rotate old logs, keep last 10
}
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$message" >> "$LOG_FILE"
    echo "$*"  # Also print to terminal
}
```

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

### Implementation Order (Recommended)
1. **Issue #3 (Logging)** - Start here. Makes debugging all other issues easier.
2. **Issue #1 (User Input)** - Critical for curl | bash usability
3. **Issue #2 (Controller Detection)** - Improves Steam Deck UX
4. **Issue #4 (Versioning)** - Can wait until Minecraft actually releases new format

## Useful Debugging

```bash
# Check generated launcher script version
head -20 ~/.local/share/PollyMC/minecraftSplitscreen.sh

# View instance configuration
cat ~/.local/share/PollyMC/instances/latestUpdate-1/instance.cfg

# Check accounts
cat ~/.local/share/PollyMC/accounts.json | jq .
```
