# Manual Test Plan — MinecraftSplitscreenSteamdeck

**Version:** 3.1.0  
**Date:** _______________  
**Tester:** _______________  
**Hardware:** _______________  
**OS / Distro:** _______________  
**PrismLauncher install type:** `[ ] Flatpak`  `[ ] AppImage`

---

> **Before you start:** run the automated suite and confirm it is READY.
> If it is not READY, do not proceed with manual testing.
>
> ```bash
> bash tests/grade.sh
> ```
>
> Result: _______________

---

## Quick reference — paths

Fill in the correct path for your install type before starting.

| Variable | Flatpak path | AppImage path |
|---|---|---|
| Data dir | `~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher` | `~/.local/share/PrismLauncher` |
| Instances | `<data dir>/instances` | `<data dir>/instances` |
| Launcher script | `<data dir>/minecraftSplitscreen.sh` | `<data dir>/minecraftSplitscreen.sh` |
| Logs | `~/.local/share/MinecraftSplitscreen/logs/` | same |

**My data dir:** _______________

---

## Phase 1 — Clean environment

> Run this phase before every full test cycle to ensure no prior state interferes.

- [ ] **1.1** Run the cleanup script
  ```bash
  bash cleanup-minecraft-splitscreen.sh --force
  ```
  Expected: completes without error, prints summary of what was removed.

- [ ] **1.2** Confirm PrismLauncher data directory is gone
  ```bash
  ls ~/.local/share/PrismLauncher 2>/dev/null || echo "clean (AppImage)"
  ls ~/.var/app/org.prismlauncher.PrismLauncher 2>/dev/null || echo "clean (Flatpak)"
  ```
  Expected: both print "clean" (or the one matching your install type).

- [ ] **1.3** Confirm launcher script is gone
  ```bash
  ls <data dir>/minecraftSplitscreen.sh 2>/dev/null || echo "gone"
  ```
  Expected: "gone"

- [ ] **1.4** Confirm logs directory is empty or absent
  ```bash
  ls ~/.local/share/MinecraftSplitscreen/logs/ 2>/dev/null || echo "no logs"
  ```
  Expected: no install-*.log files present.

**Notes:** _______________

---

## Phase 2 — Installation

### 2a. Run the installer

- [ ] **2.1** Start the installer
  ```bash
  bash install-minecraft-splitscreen.sh
  ```
  Expected: no crash, no "command not found" errors, clean completion message.

  Actual Minecraft version selected: _______________  
  Actual Fabric version: _______________

- [ ] **2.2** Installer exits 0 (success)
  ```bash
  echo "Exit code: $?"
  ```
  Expected: `Exit code: 0`

### 2b. Log file

- [ ] **2.3** Install log was created
  ```bash
  ls ~/.local/share/MinecraftSplitscreen/logs/install-*.log
  ```
  Expected: one file present.  
  Log file name: _______________

- [ ] **2.4** Log contains no ERROR lines
  ```bash
  grep -i "error\|fail" ~/.local/share/MinecraftSplitscreen/logs/install-*.log \
    | grep -v "# ignore" || echo "clean"
  ```
  Expected: "clean" or only expected/handled warnings.

  Any unexpected errors: _______________

### 2c. PrismLauncher installed

- [ ] **2.5** PrismLauncher is accessible
  ```bash
  # Flatpak:
  flatpak run org.prismlauncher.PrismLauncher --version

  # AppImage:
  ~/.local/share/PrismLauncher/PrismLauncher.AppImage --version
  ```
  Expected: prints a version string without error.  
  Version reported: _______________

### 2d. Instance directories

- [ ] **2.6** All four instance directories exist
  ```bash
  for i in 1 2 3 4; do
      ls -d <data dir>/instances/latestUpdate-$i && echo "OK"
  done
  ```
  Expected: four "OK" lines.

- [ ] **2.7** Each instance.cfg has correct fields
  ```bash
  for i in 1 2 3 4; do
      echo "=== latestUpdate-$i ==="
      grep "InstanceType\|IntendedVersion" \
          <data dir>/instances/latestUpdate-$i/instance.cfg
  done
  ```
  Expected: `InstanceType=OneSix` and `IntendedVersion=<chosen version>` for all four.

- [ ] **2.8** Each mmc-pack.json is valid and contains correct component UIDs
  ```bash
  for i in 1 2 3 4; do
      echo "=== latestUpdate-$i ==="
      jq '.components[].uid' \
          <data dir>/instances/latestUpdate-$i/mmc-pack.json
  done
  ```
  Expected: `net.minecraft`, `net.fabricmc.fabric-loader`, `org.lwjgl3` present in all four.

### 2e. Generated launcher script

- [ ] **2.9** Launcher script exists and is executable
  ```bash
  ls -l <data dir>/minecraftSplitscreen.sh
  ```
  Expected: `-rwxr-xr-x` permissions.

- [ ] **2.10** Script passes syntax check
  ```bash
  bash -n <data dir>/minecraftSplitscreen.sh && echo "syntax OK"
  ```
  Expected: `syntax OK`

- [ ] **2.11** No unreplaced placeholders
  ```bash
  grep -c '__LAUNCHER_' <data dir>/minecraftSplitscreen.sh || true
  ```
  Expected: `0`

- [ ] **2.12** Script references correct launcher type
  ```bash
  head -30 <data dir>/minecraftSplitscreen.sh | grep -i "flatpak\|appimage"
  ```
  Expected: matches your install type.

### 2f. Mods installed

- [ ] **2.13** Mod JARs present in at least one instance
  ```bash
  ls <data dir>/instances/latestUpdate-1/.minecraft/mods/*.jar
  ```
  Expected: fabric-api, controllable, splitscreen-support JARs visible.

  Mods found: _______________

**Phase 2 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 3 — Single-player launch

> For this phase, have exactly **one** controller connected or use keyboard/mouse.

- [ ] **3.1** Launch the script in static mode
  ```bash
  <data dir>/minecraftSplitscreen.sh --mode=static
  ```
  Expected: no immediate crash; Minecraft window begins to appear.

- [ ] **3.2** Minecraft main menu appears
  Wait up to 3 minutes for first launch (library download).  
  Expected: Minecraft title screen visible.

  Time to main menu: _______________

- [ ] **3.3** No crash to desktop
  Expected: window stays open.

- [ ] **3.4** Launcher log created
  ```bash
  ls ~/.local/share/MinecraftSplitscreen/logs/launcher-*.log
  ```
  Expected: one file present.

- [ ] **3.5** Log contains no ERROR lines
  ```bash
  grep -i "error\|fail" ~/.local/share/MinecraftSplitscreen/logs/launcher-*.log \
    | grep -v "# ignore" || echo "clean"
  ```

- [ ] **3.6** Load a singleplayer world and walk around
  Expected: game is playable with no obvious issues.

**Phase 3 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 4 — Static 2-player splitscreen

> Have **exactly two controllers** connected before launching.

- [ ] **4.1** Launch static mode with 2 controllers connected
  ```bash
  <data dir>/minecraftSplitscreen.sh --mode=static
  ```
  Expected: two Minecraft windows launch.

- [ ] **4.2** Both windows open and reach the main menu

  P1 window: `[ ] yes  [ ] no`  
  P2 window: `[ ] yes  [ ] no`

- [ ] **4.3** Window layout is correct
  Expected: windows fill the screen without overlap.  
  `[ ] side-by-side`  `[ ] top-bottom`  `[ ] other: _______________`

- [ ] **4.4** P1 controller moves only P1's character
  Test: move P1 joystick → only P1's view/character moves.  
  `[ ] pass  [ ] fail`

- [ ] **4.5** P2 controller moves only P2's character
  Test: move P2 joystick → only P2's view/character moves.  
  `[ ] pass  [ ] fail`

- [ ] **4.6** No double-input (P1 controls also affecting P2 or vice versa)
  `[ ] pass  [ ] fail`

- [ ] **4.7** Both windows exit cleanly when Quit is selected in-game
  Expected: both windows close, terminal returns prompt.  
  `[ ] pass  [ ] fail`

**Phase 4 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 5 — Static 3- and 4-player splitscreen

> Optional but valuable if you have enough controllers.

- [ ] **5.1** 3-player: 3 windows launch and fill screen correctly
  Layout: `[ ] 2-top + 1-bottom-left + placeholder  [ ] other: _______________`  
  Placeholder window (black fill for P4 slot): `[ ] visible  [ ] not visible  [ ] N/A`

- [ ] **5.2** 4-player: 4 windows launch in a 2×2 grid
  `[ ] pass  [ ] fail  [ ] not tested`

- [ ] **5.3** All controllers independently control their player in 3/4-player mode
  `[ ] pass  [ ] fail  [ ] not tested`

**Phase 5 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 6 — Dynamic mode session

> Dynamic mode allows players to join and leave mid-session.
> Have controllers ready to plug in/unplug.

### 6a. Start with no controllers

- [ ] **6.1** Launch in dynamic mode with no controllers connected
  ```bash
  <data dir>/minecraftSplitscreen.sh --mode=dynamic
  ```
  Expected: "Waiting for Controllers" message (notification or log), no crash.

  `[ ] waiting message seen  [ ] crashed  [ ] other: _______________`

### 6b. Player join

- [ ] **6.2** Connect first controller
  Expected: Minecraft window opens for P1 within ~30 seconds.  
  Time to P1 window: _______________

- [ ] **6.3** Connect second controller
  Expected: P2's Minecraft window opens alongside P1.  
  Layout adjusts to split-screen: `[ ] yes  [ ] no`

### 6c. Player leave

- [ ] **6.4** Disconnect P2's controller
  Expected: P2's window closes. P1's window expands to fill screen.  
  `[ ] window closed  [ ] window stayed  [ ] layout adjusted`

- [ ] **6.5** P1 continues to run normally after P2 leaves
  `[ ] pass  [ ] fail`

### 6d. Reconnect (Issue #10 validation)

- [ ] **6.6** Reconnect P2's controller
  Expected: P2's window relaunches.  
  `[ ] relaunched  [ ] did not relaunch`

  > Note: if P2 disconnects and reconnects within the same second (polling
  > fallback window), a second disconnect+reconnect may be needed.

### 6e. Session end

- [ ] **6.7** Quit both Minecraft instances
  Expected: after both exit, dynamic mode session ends and terminal returns prompt.  
  `[ ] session ended cleanly  [ ] hung`

  Time from last exit to session end: _______________

**Phase 6 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 7 — 3-player placeholder window (Issue #11)

> Only testable with exactly 3 controllers.

- [ ] **7.1** Launch dynamic mode with 3 controllers connected (or connect 3 after starting)
  Expected: 3 Minecraft windows + solid black window in P4 (bottom-right) position.  
  `[ ] black window visible  [ ] no black window  [ ] not tested`

- [ ] **7.2** Connect 4th controller
  Expected: black window disappears, P4 Minecraft launches in that slot.  
  `[ ] pass  [ ] not tested`

- [ ] **7.3** Disconnect one player (back to 3)
  Expected: black placeholder reappears in the empty slot.  
  `[ ] pass  [ ] not tested`

**Phase 7 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 8 — Steam Deck specific

> Skip this phase on standard Linux desktop.

- [ ] **8.1** Steam shortcut was created during installation
  ```bash
  grep -rl "minecraftSplitscreen" ~/.steam/steam/userdata/*/config/ 2>/dev/null \
    | head -2 || echo "not found"
  ```
  `[ ] shortcut found  [ ] not found`

- [ ] **8.2** "Minecraft Splitscreen" appears in Steam library
  `[ ] yes  [ ] no`

- [ ] **8.3** Launch from Game Mode (via Steam)
  Expected: gamescope handles the windows, no desktop visible.  
  `[ ] works  [ ] fails  [ ] not tested`

- [ ] **8.4** Steam Deck built-in controls act as P1 (no external controller needed)
  `[ ] works  [ ] fails  [ ] not tested`

- [ ] **8.5** External controllers detected alongside built-in
  `[ ] works  [ ] fails  [ ] not tested`

**Phase 8 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 9 — CLI argument validation

- [ ] **9.1** `--help` flag prints usage and exits cleanly
  ```bash
  <data dir>/minecraftSplitscreen.sh --help
  echo "Exit code: $?"
  ```
  Expected: usage text printed, exit 0.

- [ ] **9.2** `--mode=static` skips mode selection prompt
  ```bash
  <data dir>/minecraftSplitscreen.sh --mode=static
  ```
  Expected: goes straight to launching without prompting.

- [ ] **9.3** `--mode=dynamic` skips mode selection prompt
  ```bash
  <data dir>/minecraftSplitscreen.sh --mode=dynamic
  ```
  Expected: goes straight to dynamic mode without prompting.

- [ ] **9.4** Invalid flag shows an error and exits non-zero
  ```bash
  <data dir>/minecraftSplitscreen.sh --invalid-flag
  echo "Exit code: $?"
  ```
  Expected: error message, non-zero exit.

**Phase 9 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 10 — Cleanup and reinstall

> Validates the uninstaller works and a fresh reinstall succeeds.

- [ ] **10.1** Run cleanup in dry-run mode
  ```bash
  bash cleanup-minecraft-splitscreen.sh --dry-run
  ```
  Expected: lists what would be removed without removing anything.

- [ ] **10.2** Run full cleanup
  ```bash
  bash cleanup-minecraft-splitscreen.sh --force
  ```
  Expected: clean exit.

- [ ] **10.3** Reinstall from scratch completes without error
  ```bash
  bash install-minecraft-splitscreen.sh
  ```
  Expected: same result as Phase 2.

- [ ] **10.4** Launcher script from reinstall works
  Run Phase 3 checkpoint 3.1 again.  
  `[ ] pass  [ ] fail`

**Phase 10 pass/fail:** _______________  
**Notes:** _______________

---

## Summary

| Phase | Description | Result | Notes |
|---|---|---|---|
| 1 | Clean environment | | |
| 2 | Installation | | |
| 3 | Single-player launch | | |
| 4 | Static 2-player | | |
| 5 | Static 3/4-player | | |
| 6 | Dynamic mode session | | |
| 7 | 3-player placeholder | | |
| 8 | Steam Deck specific | | |
| 9 | CLI arguments | | |
| 10 | Cleanup and reinstall | | |

**Overall result:** `[ ] PASS  [ ] FAIL  [ ] PARTIAL`

**Blocking issues found:**

1. _______________
2. _______________
3. _______________

**Non-blocking issues found:**

1. _______________
2. _______________

**Tester sign-off:** _______________ **Date:** _______________
