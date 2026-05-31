# Manual Test Plan — MinecraftSplitscreenSteamdeck

**Version:** 3.1.0  
**Date:** _______________  
**Tester:** _______________  
**Hardware:** _______________  
**OS / Distro:** _______________  
**PrismLauncher install type:** `[ ] Flatpak`  `[ ] AppImage`  
**inotify-tools installed:** `[ ] yes  [ ] no`  
**xdotool / wmctrl installed:** `[ ] yes  [ ] no`

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
| Install logs | `~/.local/share/MinecraftSplitscreen/logs/install-*.log` | same |
| Launcher logs | `~/.local/share/MinecraftSplitscreen/logs/launcher-*.log` | same |
| Desktop shortcut | `~/Desktop/MinecraftSplitscreen.desktop` | same |

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
  Expected: the path for your install type prints "clean".

- [ ] **1.3** Confirm logs directory is empty or absent
  ```bash
  ls ~/.local/share/MinecraftSplitscreen/logs/ 2>/dev/null || echo "no logs"
  ```
  Expected: no `install-*.log` files present.

**Notes:** _______________

---

## Phase 2 — Installation

### 2a. Run the installer

- [ ] **2.1** Start the installer
  ```bash
  bash install-minecraft-splitscreen.sh
  ```
  Expected: no crash, no "command not found" errors, clean completion message.

  Minecraft version selected: _______________  
  Fabric version: _______________

- [ ] **2.2** Installer exits 0
  ```bash
  echo "Exit code: $?"
  ```
  Expected: `Exit code: 0`

### 2b. Log file

- [ ] **2.3** Install log was created
  ```bash
  ls ~/.local/share/MinecraftSplitscreen/logs/install-*.log
  ```
  Expected: one file present. Log file: _______________

- [ ] **2.4** Log contains no unexpected ERROR lines
  ```bash
  grep -i "error\|fail" ~/.local/share/MinecraftSplitscreen/logs/install-*.log \
    | grep -v "# ignore" || echo "clean"
  ```
  Unexpected errors: _______________

### 2c. Java version

- [ ] **2.5** Java was detected or installed at the correct version
  ```bash
  grep -i "java\|jdk" ~/.local/share/MinecraftSplitscreen/logs/install-*.log \
    | grep -i "detected\|found\|version\|install" | tail -5
  ```
  Expected: Java 21 for Minecraft 1.21+; Java 17 for 1.18–1.20.  
  Java version found: _______________

  > Wrong Java version = silent Minecraft launch failure. Verify this before proceeding.

### 2d. PrismLauncher installed

- [ ] **2.6** PrismLauncher is accessible
  ```bash
  # Flatpak:
  flatpak run org.prismlauncher.PrismLauncher --version

  # AppImage:
  ~/.local/share/PrismLauncher/PrismLauncher.AppImage --version
  ```
  Expected: version string printed without error.  
  PrismLauncher version: _______________

### 2e. Offline accounts configured

- [ ] **2.7** accounts.json was downloaded and written
  ```bash
  cat <data dir>/accounts.json | python3 -m json.tool | \
      python3 -c "import sys,json; d=json.load(sys.stdin); \
      [print(a['profile']['name']) for a in d.get('accounts',[])]"
  ```
  Expected: `P1`, `P2`, `P3`, `P4` all appear in the output alongside any
  existing accounts you may already have.

  Accounts found: _______________

  > If this step fails (network unavailable during install), Minecraft will
  > still launch but player identification in splitscreen may be affected.

- [ ] **2.8** Microsoft account is set up in PrismLauncher (REQUIRED to play)

  Open PrismLauncher and navigate to **Accounts** settings.
  
  `[ ] Microsoft account present  [ ] No account — add one now before continuing`

  > Without a valid Microsoft account, Minecraft refuses to launch.
  > This step must pass before Phase 3.

### 2f. Instance directories

- [ ] **2.9** All four instance directories exist
  ```bash
  for i in 1 2 3 4; do
      ls -d <data dir>/instances/latestUpdate-$i && echo "OK $i"
  done
  ```
  Expected: four `OK N` lines.

- [ ] **2.10** Each instance.cfg has correct Minecraft version
  ```bash
  for i in 1 2 3 4; do
      echo "=== latestUpdate-$i ==="
      grep "InstanceType\|IntendedVersion" \
          <data dir>/instances/latestUpdate-$i/instance.cfg
  done
  ```
  Expected: `InstanceType=OneSix` and `IntendedVersion=<chosen version>` for all four.

- [ ] **2.11** Each mmc-pack.json contains correct component UIDs
  ```bash
  for i in 1 2 3 4; do
      echo "=== latestUpdate-$i ==="
      jq '.components[].uid' \
          <data dir>/instances/latestUpdate-$i/mmc-pack.json
  done
  ```
  Expected: `net.minecraft`, `net.fabricmc.fabric-loader`, `org.lwjgl3` in all four.

### 2g. Generated launcher script

- [ ] **2.12** Launcher script exists and is executable
  ```bash
  ls -l <data dir>/minecraftSplitscreen.sh
  ```
  Expected: `-rwxr-xr-x` permissions.

- [ ] **2.13** No unreplaced placeholders
  ```bash
  grep -c '__LAUNCHER_' <data dir>/minecraftSplitscreen.sh || true
  ```
  Expected: `0`

- [ ] **2.14** Script references correct launcher type
  ```bash
  head -30 <data dir>/minecraftSplitscreen.sh | grep -i "flatpak\|appimage"
  ```
  Expected: matches your install type.

### 2h. Mods installed

- [ ] **2.15** Mod JARs are present
  ```bash
  ls <data dir>/instances/latestUpdate-1/.minecraft/mods/*.jar
  ```
  Expected: fabric-api, controllable, splitscreen-support JARs all present.  
  Mods found: _______________

### 2i. Desktop shortcut (if you said yes to the prompt)

- [ ] **2.16** Desktop shortcut file was created
  ```bash
  cat ~/Desktop/MinecraftSplitscreen.desktop 2>/dev/null || echo "not created"
  ```
  Expected: file exists with `Exec=` pointing to the launcher script.  
  `[ ] created  [ ] not created (said no to prompt)  [ ] missing (said yes but absent)`

**Phase 2 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 3 — Single-player launch

> For this phase have exactly **one** controller connected (or keyboard/mouse only).
> Microsoft account must be configured in PrismLauncher (Phase 2.8).

### 3a. Mode selection prompt

- [ ] **3.1** Launch without a `--mode` flag — interactive prompt appears
  ```bash
  <data dir>/minecraftSplitscreen.sh
  ```
  Expected: mode selection menu printed. Prompt waits up to 15 seconds.  
  `[ ] prompt appeared  [ ] no prompt (possible: no terminal detected)`

- [ ] **3.2** Press Enter (or wait 15 seconds) to accept the default (dynamic)
  Expected: defaults to dynamic mode, begins waiting for controllers or launching.  
  `[ ] defaulted to dynamic  [ ] defaulted to static  [ ] other: _______________`

- [ ] **3.3** Type `1` and press Enter — selects static mode
  Relaunch the script and type `1` at the prompt.  
  Expected: static mode selected, proceeds to launch.  
  `[ ] pass  [ ] fail`

### 3b. Keyboard / mouse fallback (no controller)

- [ ] **3.4** Launch static mode with NO controllers connected
  ```bash
  <data dir>/minecraftSplitscreen.sh --mode=static
  ```
  Expected: `promptControllerMode()` fires — a prompt appears offering
  keyboard/mouse mode or exit.  
  `[ ] keyboard/mouse prompt appeared  [ ] launched anyway  [ ] crashed`

  > If no keyboard/mouse prompt appears and Minecraft launches 0 instances, that
  > is also acceptable behavior. Document what actually happens.

### 3c. Single-player with controller

- [ ] **3.5** Connect one controller, launch static mode
  ```bash
  <data dir>/minecraftSplitscreen.sh --mode=static
  ```
  Expected: single Minecraft window begins to appear.

- [ ] **3.6** Minecraft main menu appears
  Wait up to 3 minutes on first run (library downloads).  
  Time to main menu: _______________

- [ ] **3.7** Log a singleplayer world session
  Load a world, walk around for 30 seconds.  
  Expected: no crash, no visible errors.  
  `[ ] pass  [ ] fail`

- [ ] **3.8** Launcher log contains no errors
  ```bash
  grep -i "error\|crash\|exception" \
    ~/.local/share/MinecraftSplitscreen/logs/launcher-*.log \
    | grep -v "^#" || echo "clean"
  ```

- [ ] **3.9** Mods loaded without conflict
  In Minecraft: **Mods** button (or F3 screen) shows Fabric API, Controllable,
  Splitscreen Support all active with no red errors.  
  `[ ] all mods loaded  [ ] mod errors present: _______________`

**Phase 3 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 4 — Static 2-player splitscreen

> Have **exactly two controllers** connected before launching.

- [ ] **4.1** Launch static mode
  ```bash
  <data dir>/minecraftSplitscreen.sh --mode=static
  ```
  Expected: two Minecraft windows launch.

- [ ] **4.2** Both windows reach the main menu
  P1: `[ ] yes  [ ] no`  
  P2: `[ ] yes  [ ] no`

- [ ] **4.3** Window layout is correct (no overlap, fills screen)
  Layout: `[ ] side-by-side  [ ] top-bottom  [ ] other: _______________`

- [ ] **4.4** Controller isolation — P1 controls only P1
  Move P1 stick → only P1's view changes.  
  `[ ] pass  [ ] fail`

- [ ] **4.5** Controller isolation — P2 controls only P2
  Move P2 stick → only P2's view changes.  
  `[ ] pass  [ ] fail`

- [ ] **4.6** No double-input between players
  `[ ] pass  [ ] fail`

- [ ] **4.7** One player quits while the other continues
  P2 selects Quit in-game. Expected: P2's window closes. P1 continues running
  uninterrupted. Layout does NOT change in static mode (no event loop).  
  `[ ] P2 closed cleanly  [ ] P1 unaffected  [ ] layout unchanged`

- [ ] **4.8** Remaining player quits — both windows gone, terminal returns
  P1 selects Quit. Expected: terminal prompt returns, no hung processes.  
  `[ ] pass  [ ] fail`

  Verify no leftover java processes:
  ```bash
  pgrep -a java | grep -i minecraft || echo "none"
  ```

**Phase 4 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 5 — Static 3- and 4-player splitscreen

> Optional — requires enough controllers.

- [ ] **5.1** 3-player: 3 windows launch and fill screen
  Layout: `[ ] 2-top + 1-bottom-left + placeholder  [ ] other: _______________`  
  Black placeholder in P4 slot: `[ ] visible  [ ] absent  [ ] N/A`

- [ ] **5.2** 4-player: 4 windows in 2×2 grid
  `[ ] pass  [ ] fail  [ ] not tested`

- [ ] **5.3** All controllers independently control their player
  `[ ] pass  [ ] fail  [ ] not tested`

**Phase 5 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 6 — Dynamic mode session

> Have controllers ready to physically plug in and unplug.

### 6a. Start with no controllers

- [ ] **6.1** Launch dynamic mode with no controllers connected
  ```bash
  <data dir>/minecraftSplitscreen.sh --mode=dynamic
  ```
  Expected: "Waiting for Controllers" message — no Minecraft window yet, no crash.  
  `[ ] waiting message seen  [ ] crashed  [ ] launched anyway`

### 6b. Player join

- [ ] **6.2** Connect first controller
  Expected: P1 Minecraft window opens.  
  Time: _______________

- [ ] **6.3** Connect second controller
  Expected: P2 Minecraft window opens, layout splits.  
  `[ ] split layout  [ ] no layout change`

### 6c. Player leave — controller disconnect

- [ ] **6.4** Unplug P2's controller
  Expected: P2's window closes, P1 expands to fill screen.  
  `[ ] P2 window closed  [ ] layout adjusted  [ ] P1 unaffected`

- [ ] **6.5** P1 continues playing normally
  `[ ] pass  [ ] fail`

### 6d. Quit game but keep controller connected (Issue #10)

- [ ] **6.6** With P1 running and controller connected: quit Minecraft from inside the game
  (select Quit to Title, then Quit Game), but do NOT unplug the controller.  
  Expected: P1 window closes. No new Minecraft window launches automatically.  
  `[ ] no relaunch (correct)  [ ] relaunched (bug)`

  > This is the Issue #10 guard. The relaunch must only happen after a
  > deliberate disconnect + reconnect, not just because the game exited.

### 6e. Reconnect to rejoin

- [ ] **6.7** Unplug the controller, then plug it back in
  Expected: a new Minecraft window launches for that slot.  
  `[ ] relaunched after reconnect  [ ] did not relaunch`

### 6f. Rapid connect/disconnect

- [ ] **6.8** Quickly plug in and unplug a controller within ~1 second
  Check which monitoring method is active first:
  ```bash
  command -v inotifywait && echo "inotifywait" || echo "polling (2s)"
  ```
  - **inotifywait**: both events should be caught; no spurious launch expected.
  - **Polling**: one or both events may be missed; document observed behavior.  
  `[ ] inotifywait — both events caught  [ ] polling — events missed (expected)`

### 6g. Session end

- [ ] **6.9** Quit all running Minecraft instances from inside the game
  Expected: session ends, terminal returns prompt.  
  `[ ] clean exit  [ ] hung`

  Time from last Minecraft exit to terminal return: _______________

### 6h. Dynamic mode Ctrl+C

- [ ] **6.10** While a dynamic session is running, press Ctrl+C
  Expected: controller monitor stops, panels are restored, terminal returns.
  No `minecraftSplitscreen` or `java` processes remain.  
  ```bash
  pgrep -a java | grep -i minecraft || echo "clean"
  ```
  `[ ] clean exit  [ ] processes left behind`

**Phase 6 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 7 — Optional dependency fallback behavior

> Tests what happens when optional tools are absent. Run once per environment
> where the tool is not installed, or temporarily uninstall/mask the tool.

### 7a. Without inotify-tools (polling fallback)

- [ ] **7.1** Confirm inotifywait is absent
  ```bash
  command -v inotifywait && echo "present — mask it first" || echo "absent — proceed"
  ```

- [ ] **7.2** Launch dynamic mode; verify polling path is used
  Expected: log line "using polling for controller monitoring" (or similar).  
  Connect a controller. Expected: detected within ~2–4 seconds (not instant).  
  `[ ] polling message seen  [ ] controller detected  [ ] delay was acceptable`

- [ ] **7.3** Controller disconnect also detected within ~4 seconds
  `[ ] pass  [ ] missed event`

### 7b. Without xdotool / wmctrl (window reposition fallback)

- [ ] **7.4** On X11 only. Confirm neither xdotool nor wmctrl is present
  ```bash
  command -v xdotool || command -v wmctrl || echo "both absent — proceed"
  ```

- [ ] **7.5** Run a 2-player dynamic session; trigger a second player join
  Expected: windows are repositioned by restarting instances (not moved in place).
  Minecraft windows appear correctly sized even without the tools.  
  `[ ] windows positioned correctly  [ ] positioning broken`

### 7c. Without libnotify

- [ ] **7.6** Confirm libnotify is absent
  ```bash
  command -v notify-send || echo "absent — proceed"
  ```

- [ ] **7.7** Run dynamic mode; connect/disconnect controllers
  Expected: no notification popups (silent), but everything else works normally.  
  `[ ] no notifications  [ ] session worked normally`

**Phase 7 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 8 — 3-player placeholder window (Issue #11)

> Requires exactly 3 controllers.

- [ ] **8.1** Launch dynamic mode with 3 controllers or connect 3 after starting
  Expected: 3 Minecraft windows + solid black window in P4 (bottom-right) position.  
  `[ ] black window visible  [ ] absent  [ ] not tested`

- [ ] **8.2** Connect 4th controller
  Expected: black window disappears, P4 Minecraft launches.  
  `[ ] pass  [ ] not tested`

- [ ] **8.3** Disconnect a player (back to 3)
  Expected: black placeholder reappears in the empty slot.  
  `[ ] pass  [ ] not tested`

**Phase 8 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 9 — Steam Deck specific

> Skip on standard Linux desktop.

### 9a. Basic Steam integration

- [ ] **9.1** Steam shortcut was created during installation
  ```bash
  grep -rl "minecraftSplitscreen" ~/.steam/steam/userdata/*/config/ 2>/dev/null \
    | head -2 || echo "not found"
  ```
  `[ ] shortcut found  [ ] not found`

- [ ] **9.2** "Minecraft Splitscreen" appears in Steam library
  `[ ] yes  [ ] no`

### 9b. Game Mode launch (nestedPlasma path)

- [ ] **9.3** Launch from Game Mode via Steam shortcut
  Expected: a nested KDE Plasma session starts, mode selection prompt appears
  (or dynamic mode starts if no terminal), Minecraft launches inside gamescope.  
  `[ ] works  [ ] fails  [ ] mode prompt appeared in Game Mode`

- [ ] **9.4** Session exits cleanly from Game Mode
  Expected: Plasma logs out, Steam Game Mode returns to home screen.
  No orphaned processes.  
  `[ ] clean exit  [ ] hung  [ ] other: _______________`

### 9c. Built-in controls

- [ ] **9.5** HANDHELD_MODE: Steam Deck without external display
  Expected: only 1 player slot, built-in controls act as P1.  
  `[ ] 1 slot  [ ] built-in controls work as P1  [ ] not tested`

- [ ] **9.6** Dock to external display: additional controllers detected
  Expected: controller count increases when external controllers are connected.  
  `[ ] works  [ ] not tested`

**Phase 9 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 10 — CLI argument validation

- [ ] **10.1** `--help` prints usage and exits 0
  ```bash
  <data dir>/minecraftSplitscreen.sh --help; echo "Exit: $?"
  ```
  Expected: usage text, `Exit: 0`.

- [ ] **10.2** `--mode=static` skips mode selection
  Expected: goes straight to launching without printing mode menu.  
  `[ ] pass  [ ] fail`

- [ ] **10.3** `--mode=dynamic` skips mode selection
  `[ ] pass  [ ] fail`

- [ ] **10.4** Invalid flag exits non-zero with an error message
  ```bash
  <data dir>/minecraftSplitscreen.sh --invalid-flag; echo "Exit: $?"
  ```
  Expected: error message, non-zero exit.  
  `[ ] pass  [ ] fail`

- [ ] **10.5** Launched with no terminal (Steam / nohup) defaults to dynamic
  ```bash
  nohup <data dir>/minecraftSplitscreen.sh > /tmp/mc-nohup.out 2>&1 &
  sleep 3
  grep -i "dynamic\|no terminal\|defaulting" /tmp/mc-nohup.out || echo "not found"
  kill %1 2>/dev/null
  ```
  Expected: "no terminal detected — defaulting to dynamic mode" in output.  
  `[ ] pass  [ ] fail`

**Phase 10 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 11 — Signal handling and interruption recovery

> Verifies the system can be stopped at any point without leaving a mess.

### 11a. Interrupt during installation

- [ ] **11.1** Start the installer, press Ctrl+C partway through (after PrismLauncher installs but before instances are created)
  Expected: cleanup message printed, no partial files left in unexpected places, installer exits non-zero.  
  `[ ] clean exit  [ ] partial state left behind`

- [ ] **11.2** Run the cleanup script after the aborted install
  ```bash
  bash cleanup-minecraft-splitscreen.sh --dry-run
  ```
  Expected: dry-run shows what would be removed; no crash.  
  `[ ] pass  [ ] fail`

### 11b. Interrupt during static mode session

- [ ] **11.3** Launch static 2-player session, then Ctrl+C the launcher
  Expected: Minecraft windows close (or are left for user to close — document behavior),
  terminal returns prompt, no orphaned java processes.
  ```bash
  pgrep -a java | grep -i minecraft || echo "clean"
  ```
  `[ ] terminal returned  [ ] java processes: _______________`

### 11c. Interrupt during dynamic mode session

- [ ] **11.4** Launch dynamic mode (2 players active), then Ctrl+C
  Expected: controller monitor stops, panels restored, terminal returns.  
  `[ ] clean exit  [ ] hung  [ ] panels restored`

**Phase 11 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 12 — Reinstall over existing installation (Issue #6)

> Run WITHOUT running the cleanup script first. Tests installer behavior when
> a prior installation already exists. Issue #6 (idempotent detection) is not
> yet implemented, so the installer will overwrite — this phase documents the
> current behavior and flags if it causes corruption.

- [ ] **12.1** Confirm a working installation is in place (complete Phases 2–3 first)

- [ ] **12.2** Re-run the installer without cleanup
  ```bash
  bash install-minecraft-splitscreen.sh
  ```
  Expected (current behavior — no idempotent detection): installer runs fresh,
  overwrites instances and launcher script.  
  `[ ] completed without error  [ ] crashed`

- [ ] **12.3** Existing Microsoft account was preserved in PrismLauncher
  Open PrismLauncher → Accounts. Microsoft account should still be there.  
  `[ ] preserved  [ ] lost (bug)`

- [ ] **12.4** Offline P1–P4 accounts still present after reinstall
  ```bash
  cat <data dir>/accounts.json | python3 -c "import sys,json; \
    d=json.load(sys.stdin); \
    [print(a['profile']['name']) for a in d.get('accounts',[])]"
  ```
  `[ ] P1–P4 still present  [ ] missing`

- [ ] **12.5** Launcher still works after reinstall
  Run Phase 3 checkpoint 3.5 again.  
  `[ ] pass  [ ] fail`

**Phase 12 pass/fail:** _______________  
**Notes:** _______________

---

## Phase 13 — Cleanup and reinstall (clean cycle)

- [ ] **13.1** Dry-run cleanup
  ```bash
  bash cleanup-minecraft-splitscreen.sh --dry-run
  ```
  Expected: lists what would be removed, nothing actually deleted.

- [ ] **13.2** Full cleanup
  ```bash
  bash cleanup-minecraft-splitscreen.sh --force
  ```
  Expected: clean exit.

- [ ] **13.3** Verify Java was preserved (default: `--remove-java` not passed)
  ```bash
  ls ~/.local/jdk/ 2>/dev/null && echo "Java preserved" || echo "Java gone"
  ```
  Expected: `Java preserved`

- [ ] **13.4** Cleanup with `--remove-java`
  ```bash
  bash cleanup-minecraft-splitscreen.sh --force --remove-java
  ls ~/.local/jdk/ 2>/dev/null || echo "Java removed"
  ```
  Expected: `Java removed`

- [ ] **13.5** Fresh reinstall completes without error
  ```bash
  bash install-minecraft-splitscreen.sh
  ```
  `[ ] pass  [ ] fail`

- [ ] **13.6** Launcher from fresh reinstall works (run Phase 3.5 again)
  `[ ] pass  [ ] fail`

**Phase 13 pass/fail:** _______________  
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
| 7 | Optional dependency fallbacks | | |
| 8 | 3-player placeholder | | |
| 9 | Steam Deck specific | | |
| 10 | CLI arguments | | |
| 11 | Signal handling / interruption | | |
| 12 | Reinstall over existing install | | |
| 13 | Cleanup and clean reinstall | | |

**Overall result:** `[ ] PASS  [ ] FAIL  [ ] PARTIAL`

**Blocking issues found:**

1. _______________
2. _______________
3. _______________

**Non-blocking issues found:**

1. _______________
2. _______________

**Items deferred to next test cycle:**

1. _______________
2. _______________

**Tester sign-off:** _______________ **Date:** _______________
