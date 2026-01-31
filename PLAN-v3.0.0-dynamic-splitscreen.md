# Implementation Plan: Rev 3.0.0 - Dynamic Player Join/Leave System

## Overview

This plan details the implementation of version 3.0.0, introducing a dynamic splitscreen system where players can join and leave Minecraft sessions on-the-fly. The launcher will monitor controller connections, spawn new instances when players join, and reposition windows when the player count changes.

**Branch Strategy:** Feature development on `rev3-dynamic-splitscreen` branch, merged to `main` after validation.

---

## Requirements Summary

### Core Feature
1. **Dynamic Controller Monitoring**: Continuously watch for controller hotplug events
2. **On-the-fly Instance Spawning**: Launch new Minecraft instances when controllers connect
3. **Dynamic Window Repositioning**: Reposition existing windows when player count changes
4. **Player Exit Detection**: Detect when a player quits and reposition remaining windows
5. **Flexible Sessions**: Single player can start, others join/leave freely

### Project Management
- Create `rev3-dynamic-splitscreen` branch from `main`
- Update all version references to `3.0.0`
- Keep branch mergeable with ongoing `main` development (Rev 2.x fixes)
- Update README.md with feature documentation
- Merge to `main` only after validation

---

## Technical Feasibility: HIGH

### What Already Exists (No New Code Needed)
- **Layout Logic**: `setSplitscreenModeForPlayer()` already handles 1/2/3/4 player layouts
- **Instance Launching**: `launchGame()` function works for individual instances
- **Controller Detection**: `getControllerCount()` with Steam virtual controller filtering
- **Pre-created Instances**: `latestUpdate-1` through `latestUpdate-4` directories exist

### What Needs to Be Built
- Controller hotplug monitoring (event-driven)
- Process tracking for running instances
- Event loop for dynamic orchestration
- Window repositioning (xdotool for X11, restart for Game Mode)
- Mode selection UI (static vs dynamic)

### Key Constraint
The splitscreen mod reads `splitscreen.properties` only at startup:
- **Desktop Mode (X11)**: Use `xdotool`/`wmctrl` to move windows externally
- **Game Mode (gamescope)**: Must restart instances with new coordinates

---

## Architecture Changes

### Files Modified

| File | Change Type | Description |
|------|-------------|-------------|
| `modules/version_info.sh` | Minor | Update `SCRIPT_VERSION` to "3.0.0" |
| `modules/launcher_script_generator.sh` | Major | Add dynamic mode logic to generated script |
| `README.md` | Major | Document dynamic splitscreen feature |
| `CLAUDE.md` | Minor | Update version references, add backlog items |
| `install-minecraft-splitscreen.sh` | Minor | Version display update |

### No New Files Required
All changes fit within existing module structure.

---

## Implementation Phases

### Phase 1: Branch Setup & Version Update
**Estimated effort: 30 minutes**

#### 1.1 Create Feature Branch
```bash
git checkout main
git pull origin main
git checkout -b rev3-dynamic-splitscreen
```

#### 1.2 Update Version Constants
**File:** `modules/version_info.sh`

**Change:**
```bash
# Line 43
readonly SCRIPT_VERSION="3.0.0"
```

**Also update changelog comment:**
```bash
# @changelog
#   3.0.0 (2026-XX-XX) - Dynamic splitscreen: players can join/leave mid-session
#   2.0.0 (2026-01-24) - Updated for modular installer architecture
#   1.0.0 (2026-01-22) - Initial version
```

#### 1.3 Update Module Headers
Update `@version` in all module files to `3.0.0`:
- `modules/version_info.sh`
- `modules/utilities.sh`
- `modules/path_configuration.sh`
- `modules/launcher_setup.sh`
- `modules/launcher_script_generator.sh`
- `modules/java_management.sh`
- `modules/version_management.sh`
- `modules/lwjgl_management.sh`
- `modules/mod_management.sh`
- `modules/instance_creation.sh`
- `modules/pollymc_setup.sh`
- `modules/steam_integration.sh`
- `modules/desktop_launcher.sh`
- `modules/main_workflow.sh`

---

### Phase 2: Controller Monitoring Infrastructure
**Estimated effort: 2-3 hours**

#### 2.1 Add State Tracking Variables
**File:** `modules/launcher_script_generator.sh` (in generated script template)

**Add after existing variable declarations (~line 112):**
```bash
# =============================================================================
# Dynamic Splitscreen State (Rev 3.0.0)
# =============================================================================
declare -a INSTANCE_PIDS=("" "" "" "")     # PID for each player slot (index 0-3)
declare -a INSTANCE_ACTIVE=(0 0 0 0)       # 1 if slot is in use, 0 otherwise
CURRENT_PLAYER_COUNT=0                      # Number of active players
DYNAMIC_MODE=0                              # 1 if dynamic mode enabled
CONTROLLER_MONITOR_PID=""                   # PID of monitor subprocess
```

#### 2.2 Create Controller Monitor Function
**File:** `modules/launcher_script_generator.sh` (in generated script template)

```bash
# Monitor controller connections/disconnections
# Writes "CONTROLLER_CHANGE:<count>" to stdout when changes detected
monitorControllers() {
    local last_count
    last_count=$(getControllerCount)
    
    # Prefer inotifywait (event-driven, efficient)
    if command -v inotifywait >/dev/null 2>&1; then
        inotifywait -m -q -e create -e delete /dev/input/ 2>/dev/null | while read -r _ action file; do
            if [[ "$file" =~ ^js[0-9]+$ ]]; then
                sleep 0.5  # Debounce rapid events
                local new_count
                new_count=$(getControllerCount)
                if [ "$new_count" != "$last_count" ]; then
                    echo "CONTROLLER_CHANGE:$new_count"
                    last_count=$new_count
                fi
            fi
        done
    else
        # Fallback: poll every 2 seconds
        while true; do
            sleep 2
            local new_count
            new_count=$(getControllerCount)
            if [ "$new_count" != "$last_count" ]; then
                echo "CONTROLLER_CHANGE:$new_count"
                last_count=$new_count
            fi
        done
    fi
}

# Start controller monitoring in background
startControllerMonitor() {
    # Create a named pipe for communication
    local pipe_path="/tmp/mc-splitscreen-$$"
    mkfifo "$pipe_path" 2>/dev/null || true
    
    monitorControllers > "$pipe_path" &
    CONTROLLER_MONITOR_PID=$!
    
    # Open pipe for reading on fd 3
    exec 3< "$pipe_path"
    
    log_info "Controller monitor started (PID: $CONTROLLER_MONITOR_PID)"
}

# Stop controller monitoring
stopControllerMonitor() {
    if [ -n "$CONTROLLER_MONITOR_PID" ]; then
        kill "$CONTROLLER_MONITOR_PID" 2>/dev/null || true
        wait "$CONTROLLER_MONITOR_PID" 2>/dev/null || true
        CONTROLLER_MONITOR_PID=""
    fi
    
    # Clean up pipe
    rm -f "/tmp/mc-splitscreen-$$" 2>/dev/null || true
    exec 3<&- 2>/dev/null || true
}
```

---

### Phase 3: Instance Lifecycle Management
**Estimated effort: 2-3 hours**

#### 3.1 Instance Launch/Track Function
**File:** `modules/launcher_script_generator.sh` (in generated script template)

```bash
# Launch a single instance for a player slot
# Arguments: $1 = slot number (1-4), $2 = total players for layout
launchInstanceForSlot() {
    local slot=$1
    local total_players=$2
    local idx=$((slot - 1))
    
    # Configure splitscreen position using existing function
    setSplitscreenModeForPlayer "$slot" "$total_players"
    
    # Launch the game
    launchGame "latestUpdate-$slot" "P$slot" &
    local pid=$!
    
    # Track the instance
    INSTANCE_PIDS[$idx]=$pid
    INSTANCE_ACTIVE[$idx]=1
    
    log_info "Launched instance $slot (PID: $pid)"
}

# Check if an instance is still running
isInstanceRunning() {
    local slot=$1
    local idx=$((slot - 1))
    local pid="${INSTANCE_PIDS[$idx]}"
    
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Get next available slot (1-4), returns empty if all full
getNextAvailableSlot() {
    for i in 1 2 3 4; do
        local idx=$((i - 1))
        if [ "${INSTANCE_ACTIVE[$idx]}" = "0" ]; then
            echo "$i"
            return 0
        fi
    done
    echo ""
}

# Count currently active instances
countActiveInstances() {
    local count=0
    for i in 0 1 2 3; do
        if [ "${INSTANCE_ACTIVE[$i]}" = "1" ]; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

# Mark an instance as stopped
markInstanceStopped() {
    local slot=$1
    local idx=$((slot - 1))
    INSTANCE_PIDS[$idx]=""
    INSTANCE_ACTIVE[$idx]=0
}
```

---

### Phase 4: Window Repositioning
**Estimated effort: 3-4 hours**

#### 4.1 Window Management Detection
**File:** `modules/launcher_script_generator.sh` (in generated script template)

```bash
# Check if external window management is available
canUseExternalWindowManagement() {
    # Must be on X11 and have xdotool or wmctrl
    if [ -z "$DISPLAY" ]; then
        return 1
    fi
    
    # Not available in gamescope/Game Mode
    if isSteamDeckGameMode; then
        return 1
    fi
    
    # Check for tools
    command -v xdotool >/dev/null 2>&1 || command -v wmctrl >/dev/null 2>&1
}

# Get window ID for a Minecraft instance by PID
getWindowIdForPid() {
    local pid=$1
    
    if command -v xdotool >/dev/null 2>&1; then
        # xdotool can search by PID
        xdotool search --pid "$pid" 2>/dev/null | head -1
    elif command -v wmctrl >/dev/null 2>&1; then
        # wmctrl needs window list parsing
        wmctrl -lp 2>/dev/null | awk -v pid="$pid" '$3 == pid {print $1; exit}'
    fi
}

# Move and resize a window
moveResizeWindow() {
    local window_id=$1
    local x=$2 y=$3 width=$4 height=$5
    
    if [ -z "$window_id" ]; then
        return 1
    fi
    
    if command -v xdotool >/dev/null 2>&1; then
        xdotool windowmove "$window_id" "$x" "$y"
        xdotool windowsize "$window_id" "$width" "$height"
    elif command -v wmctrl >/dev/null 2>&1; then
        wmctrl -i -r "$window_id" -e "0,$x,$y,$width,$height"
    fi
}
```

#### 4.2 Layout Positioning Logic
**File:** `modules/launcher_script_generator.sh` (in generated script template)

```bash
# Get screen dimensions
getScreenDimensions() {
    local width=1920
    local height=1080
    
    if command -v xdpyinfo >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
        local dims
        dims=$(xdpyinfo 2>/dev/null | grep dimensions | awk '{print $2}')
        if [ -n "$dims" ]; then
            width=$(echo "$dims" | cut -dx -f1)
            height=$(echo "$dims" | cut -dx -f2)
        fi
    fi
    
    echo "$width $height"
}

# Calculate window geometry for external positioning
# Returns: x y width height
calculateWindowPosition() {
    local slot=$1
    local total_players=$2
    local screen_width=$3
    local screen_height=$4
    
    case "$total_players" in
        1)
            echo "0 0 $screen_width $screen_height"
            ;;
        2)
            local half_height=$((screen_height / 2))
            case "$slot" in
                1) echo "0 0 $screen_width $half_height" ;;
                2) echo "0 $half_height $screen_width $half_height" ;;
            esac
            ;;
        3|4)
            local half_width=$((screen_width / 2))
            local half_height=$((screen_height / 2))
            case "$slot" in
                1) echo "0 0 $half_width $half_height" ;;
                2) echo "$half_width 0 $half_width $half_height" ;;
                3) echo "0 $half_height $half_width $half_height" ;;
                4) echo "$half_width $half_height $half_width $half_height" ;;
            esac
            ;;
    esac
}

# Reposition all active windows for new player count
repositionAllWindows() {
    local new_total=$1
    
    read -r screen_width screen_height < <(getScreenDimensions)
    
    if canUseExternalWindowManagement; then
        log_info "Repositioning windows via xdotool/wmctrl for $new_total players"
        
        local slot_num=0
        for i in 1 2 3 4; do
            local idx=$((i - 1))
            if [ "${INSTANCE_ACTIVE[$idx]}" = "1" ]; then
                slot_num=$((slot_num + 1))
                local pid="${INSTANCE_PIDS[$idx]}"
                local window_id
                window_id=$(getWindowIdForPid "$pid")
                
                if [ -n "$window_id" ]; then
                    read -r x y w h < <(calculateWindowPosition "$slot_num" "$new_total" "$screen_width" "$screen_height")
                    moveResizeWindow "$window_id" "$x" "$y" "$w" "$h"
                    log_info "Repositioned window for slot $i to ${x},${y} ${w}x${h}"
                fi
            fi
        done
    else
        log_warning "External window management not available"
        log_info "Updating splitscreen.properties and restarting instances"
        repositionWithRestart "$new_total"
    fi
}

# Reposition by restarting instances (Game Mode fallback)
repositionWithRestart() {
    local new_total=$1
    
    # Stop all instances
    for i in 1 2 3 4; do
        local idx=$((i - 1))
        if [ "${INSTANCE_ACTIVE[$idx]}" = "1" ]; then
            local pid="${INSTANCE_PIDS[$idx]}"
            if [ -n "$pid" ]; then
                log_info "Stopping instance $i for repositioning"
                kill "$pid" 2>/dev/null || true
            fi
        fi
    done
    
    # Wait for all to exit
    sleep 2
    
    # Relaunch active instances with new positions
    local slot_num=0
    for i in 1 2 3 4; do
        local idx=$((i - 1))
        if [ "${INSTANCE_ACTIVE[$idx]}" = "1" ]; then
            slot_num=$((slot_num + 1))
            launchInstanceForSlot "$i" "$new_total"
        fi
    done
}
```

---

### Phase 5: Main Event Loop
**Estimated effort: 3-4 hours**

#### 5.1 Event Handlers
**File:** `modules/launcher_script_generator.sh` (in generated script template)

```bash
# Handle controller count change
handleControllerChange() {
    local new_controller_count=$1
    local current_active
    current_active=$(countActiveInstances)
    
    log_info "Controller change detected: $new_controller_count controllers (currently $current_active active)"
    
    # Add new instances if controllers increased and we have room
    while [ "$current_active" -lt "$new_controller_count" ] && [ "$current_active" -lt 4 ]; do
        local slot
        slot=$(getNextAvailableSlot)
        if [ -n "$slot" ]; then
            local new_total=$((current_active + 1))
            log_info "Player $new_total joining (slot $slot)"
            showNotification "Player Joined" "Player $new_total is joining the game"
            
            # Update ALL windows for new layout
            repositionAllWindows "$new_total"
            
            # Launch the new instance
            launchInstanceForSlot "$slot" "$new_total"
            current_active=$new_total
        else
            break
        fi
    done
    
    CURRENT_PLAYER_COUNT=$current_active
}

# Check for and handle exited instances
checkForExitedInstances() {
    local any_exited=0
    
    for i in 1 2 3 4; do
        local idx=$((i - 1))
        if [ "${INSTANCE_ACTIVE[$idx]}" = "1" ]; then
            if ! isInstanceRunning "$i"; then
                log_info "Player $i has exited"
                showNotification "Player Left" "Player $i has left the game"
                markInstanceStopped "$i"
                any_exited=1
            fi
        fi
    done
    
    if [ "$any_exited" = "1" ]; then
        local remaining
        remaining=$(countActiveInstances)
        CURRENT_PLAYER_COUNT=$remaining
        
        if [ "$remaining" -gt 0 ]; then
            log_info "Repositioning for $remaining remaining players"
            repositionAllWindows "$remaining"
        fi
    fi
}

# Show desktop notification
showNotification() {
    local title="$1"
    local message="$2"
    
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Minecraft Splitscreen" "$title" "$message" 2>/dev/null || true
    fi
}
```

#### 5.2 Dynamic Mode Main Loop
**File:** `modules/launcher_script_generator.sh` (in generated script template)

```bash
# Run dynamic splitscreen mode
runDynamicSplitscreen() {
    log_info "Starting dynamic splitscreen mode"
    DYNAMIC_MODE=1
    local instances_ever_launched=0
    
    # Start controller monitoring
    startControllerMonitor
    
    # Initial launch based on current controllers
    local initial_count
    initial_count=$(getControllerCount)
    if [ "$initial_count" -gt 0 ]; then
        handleControllerChange "$initial_count"
        instances_ever_launched=1
    else
        log_info "No controllers detected. Waiting for controller connection..."
        showNotification "Waiting for Controllers" "Connect a controller to start playing"
    fi
    
    # Main event loop
    while true; do
        # Check for controller events (non-blocking read with timeout)
        if read -t 1 -u 3 event 2>/dev/null; then
            if [[ "$event" =~ ^CONTROLLER_CHANGE:([0-9]+)$ ]]; then
                handleControllerChange "${BASH_REMATCH[1]}"
                instances_ever_launched=1
            fi
        fi
        
        # Check for exited instances
        checkForExitedInstances
        
        # Exit if all players have left (and at least one ever played)
        local active
        active=$(countActiveInstances)
        if [ "$active" -eq 0 ] && [ "$instances_ever_launched" = "1" ]; then
            log_info "All players have exited. Ending session."
            break
        fi
    done
    
    # Cleanup
    stopControllerMonitor
    log_info "Dynamic splitscreen session ended"
}

# Run static splitscreen mode (original behavior)
runStaticSplitscreen() {
    log_info "Starting static splitscreen mode"
    DYNAMIC_MODE=0
    
    local numberOfControllers
    numberOfControllers=$(getControllerCount)
    
    echo "[Info] Detected $numberOfControllers controller(s), launching splitscreen instances..."
    
    for player in $(seq 1 "$numberOfControllers"); do
        setSplitscreenModeForPlayer "$player" "$numberOfControllers"
        echo "[Info] Launching instance $player of $numberOfControllers (latestUpdate-$player)"
        launchGame "latestUpdate-$player" "P$player"
    done
    
    echo "[Info] All instances launched. Waiting for games to exit..."
    wait
    echo "[Info] All games have exited."
}
```

#### 5.3 Mode Selection UI
**File:** `modules/launcher_script_generator.sh` (in generated script template)

Update main entry point:

```bash
# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

# Enable debug output with SPLITSCREEN_DEBUG=1
if [ "${SPLITSCREEN_DEBUG:-0}" = "1" ]; then
    echo "[Debug] === Minecraft Splitscreen Launcher v__SCRIPT_VERSION__ ===" >&2
    echo "[Debug] Launcher: $LAUNCHER_NAME ($LAUNCHER_TYPE)" >&2
    echo "[Debug] Instances: $INSTANCES_DIR" >&2
    echo "[Debug] Environment: XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP DISPLAY=$DISPLAY" >&2
fi

# Mode selection (skip if launched with argument)
LAUNCH_MODE="${1:-}"

if [ -z "$LAUNCH_MODE" ] && [ "$1" != "launchFromPlasma" ]; then
    echo ""
    echo "=== Minecraft Splitscreen Launcher v__SCRIPT_VERSION__ ==="
    echo ""
    echo "Launch Modes:"
    echo "  1. Static  - Launch based on current controllers (original behavior)"
    echo "  2. Dynamic - Players can join/leave during session [NEW]"
    echo ""
    read -t 10 -p "Select mode [1]: " mode_choice || mode_choice=""
    mode_choice=${mode_choice:-1}
    
    case "$mode_choice" in
        2|dynamic|d) LAUNCH_MODE="dynamic" ;;
        *) LAUNCH_MODE="static" ;;
    esac
fi

if isSteamDeckGameMode; then
    if [ "$1" = "launchFromPlasma" ]; then
        # Inside nested Plasma session
        rm -f ~/.config/autostart/minecraft-launch.desktop
        
        if [ "$LAUNCH_MODE" = "dynamic" ]; then
            runDynamicSplitscreen
        else
            launchGames
        fi
        
        qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout
    else
        # Start nested session (pass mode)
        nestedPlasma "$LAUNCH_MODE"
    fi
else
    # Desktop mode
    if [ "$LAUNCH_MODE" = "dynamic" ]; then
        runDynamicSplitscreen
    else
        runStaticSplitscreen
    fi
fi
```

---

### Phase 6: Documentation Updates
**Estimated effort: 2-3 hours**

#### 6.1 README.md Updates

Add new section after "Features":

```markdown
## Dynamic Splitscreen Mode (v3.0.0)

Version 3.0.0 introduces **Dynamic Splitscreen** - players can now join and leave mid-session without everyone needing to start at the same time.

### How It Works

1. **Launch the game** - Choose "Dynamic" mode when prompted
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
```

Update "Recent Improvements" section:

```markdown
## Recent Improvements
- ✅ **Dynamic Splitscreen (v3.0.0)**: Players can join and leave mid-session - no need for everyone to start at the same time
- ✅ **Controller Hotplug**: Real-time detection of controller connections/disconnections
- ✅ **Automatic Window Repositioning**: Windows automatically resize when player count changes
- ✅ **Desktop Notifications**: Get notified when players join or leave
- [existing items...]
```

#### 6.2 CLAUDE.md Updates

Update version references and add to backlog:

```markdown
**Version:** 3.0.0
```

Add to Active Development Backlog:

```markdown
### Issue #5: Dynamic Splitscreen Mode (v3.0.0) - IMPLEMENTED
**Feature:** Players can join and leave mid-session without coordinating start times.

**Technical Implementation:**
- Controller monitoring via `inotifywait` with polling fallback
- Process tracking with PID arrays for 4 instance slots
- External window repositioning via `xdotool`/`wmctrl` on X11
- Instance restart fallback for Game Mode
- Event loop architecture in generated launcher script

**Files modified:**
- `modules/launcher_script_generator.sh` - Major changes for dynamic mode
- `modules/version_info.sh` - Version bump to 3.0.0
- `README.md` - Feature documentation
- All module headers - Version update
```

---

### Phase 7: Testing & Validation
**Estimated effort: 4-6 hours**

#### 7.1 Test Matrix

| Scenario | Environment | Expected Behavior |
|----------|-------------|-------------------|
| 1 controller start, 2nd joins | Desktop X11 | Spawn P2, reposition via xdotool |
| 1 controller start, 2nd joins | Steam Deck Game Mode | Spawn P2, restart P1 with new position |
| P2 quits Minecraft | All | Reposition P1 to fullscreen |
| Controller disconnect (player still in game) | All | No action (avoid false positives) |
| 4 players, P2 quits | All | Reposition remaining 3 players |
| No controllers at start | All | Wait for controller, show notification |
| Static mode selected | All | Original behavior unchanged |
| `inotifywait` not installed | All | Fall back to polling |
| `xdotool` not installed | Desktop | Log warning, use restart method |

#### 7.2 Merge Preparation

Before merging to `main`:
1. Rebase onto latest `main` to incorporate Rev 2.x fixes
2. Run full test matrix
3. Test fresh installation via `curl | bash`
4. Test upgrade from Rev 2.x installation
5. Verify version displays correctly throughout

---

## Git Workflow

### Branch Strategy
```
main (2.0.x) ─────────────────────────────────────────► (continues)
     │                                                      │
     └── rev3-dynamic-splitscreen (3.0.0) ─────────────────┘
                                                    (merge when validated)
```

### Keeping Branch Current
```bash
# Periodically sync with main
git checkout rev3-dynamic-splitscreen
git fetch origin
git rebase origin/main
# Resolve any conflicts
git push --force-with-lease
```

### Merge Process
```bash
# After validation
git checkout main
git merge --no-ff rev3-dynamic-splitscreen -m "feat: Dynamic splitscreen mode (v3.0.0)"
git tag v3.0.0
git push origin main --tags
```

---

## Dependencies

### Required (already available)
- Bash 4.0+
- Standard Linux utilities
- PollyMC launcher

### Recommended (for best dynamic mode experience)
| Package | Purpose | Fallback |
|---------|---------|----------|
| `inotify-tools` | Efficient controller event detection | Polling every 2 seconds |
| `xdotool` | X11 window positioning | Instance restart |
| `wmctrl` | Alternative X11 window management | Instance restart |
| `libnotify` | Desktop notifications | Silent operation |

---

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| Splitscreen mod doesn't reload config | HIGH | Use external window tools on X11; restart on Game Mode |
| Wayland incompatibility | MEDIUM | Document limitation; most gaming distros use X11 |
| Steam virtual controller issues | LOW | Existing `getControllerCount()` filtering handles this |
| Rev 2.x merge conflicts | LOW | Modular architecture isolates changes to launcher_script_generator.sh |

---

## Complexity Summary

| Phase | Effort | Risk |
|-------|--------|------|
| 1. Branch Setup & Version | 30 min | Low |
| 2. Controller Monitoring | 2-3 hours | Medium |
| 3. Instance Lifecycle | 2-3 hours | Low |
| 4. Window Repositioning | 3-4 hours | High |
| 5. Main Event Loop | 3-4 hours | Medium |
| 6. Documentation | 2-3 hours | Low |
| 7. Testing | 4-6 hours | Medium |
| **Total** | **17-24 hours** | **Medium-High** |

---

## Success Criteria

- [ ] Single player can start and play alone
- [ ] New controller connection launches new instance automatically
- [ ] Windows reposition correctly for 1/2/3/4 player configurations
- [ ] Player quitting Minecraft triggers repositioning of remaining windows
- [ ] Works on Steam Deck Desktop Mode with xdotool
- [ ] Works on Steam Deck Game Mode with restart method
- [ ] Static mode unchanged from Rev 2.x behavior
- [ ] Version 3.0.0 displays correctly at install and runtime
- [ ] README documents the feature completely
- [ ] Branch merges cleanly with ongoing main development
- [ ] All existing tests continue to pass

---

## WAITING FOR CONFIRMATION

This plan is ready for implementation. Do you want me to:

1. **Proceed with this plan** - Start with Phase 1 (branch creation and version updates)
2. **Modify the plan** - Adjust scope, ordering, or approach
3. **Ask clarifying questions** - Get more details on specific aspects
