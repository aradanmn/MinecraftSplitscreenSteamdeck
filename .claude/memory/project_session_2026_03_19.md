# Session 2026-03-19 — Issue #10 Fix, Test Harness, Controllable Research

## What was done

### Issue #10 Fix: Disconnect+Reconnect Before Relaunch (launcher_script_generator.sh v3.2.5)
**Problem:** `checkForExitedInstances()` was syncing `KNOWN_CONTROLLER_COUNT` down to the
remaining active instance count when an instance exited. Any subsequent CONTROLLER_CHANGE event
(spurious inotifywait, polling tick, another player's controller) could then trigger an
unintended relaunch — no physical disconnect required.

**Fix:** Removed the KNOWN sync from `checkForExitedInstances()` entirely. KNOWN now only
changes via actual controller events in `handleControllerChange()`. The correct relaunch
sequence is now enforced:
1. Instance exits, controller stays connected → KNOWN stays at real count → no relaunch
2. Player physically disconnects → CONTROLLER_CHANGE:N-1 → scale-down sets KNOWN=N-1
3. Player reconnects → CONTROLLER_CHANGE:N → slots_to_launch=1 → relaunch ✓

Added per-slot logging: "Slot X: instance exited but controller still connected — disconnect
and reconnect controller to rejoin"

**Trade-off:** In polling fallback mode (no inotifywait), a very fast disconnect+reconnect
(<2s) may be missed. With inotifywait (primary) every event is caught immediately.

### Test Harness: tools/test-dynamic-mode.sh (new file)
SSH-friendly test harness for the dynamic splitscreen event loop. No display, no PrismLauncher required.

**How it works:**
- Sources generated launcher script function defs (lines 1–2253) via process substitution
- Bypasses `validate_launcher` exit by injecting a mock override between lines 170 and 172
- Mocks: `launchGame` → `sleep 300`, `assignControllerToSlot/setSplitscreenModeForPlayer/
  initSdlWrappers/inhibitScreen/hidePanels/repositionAllWindows/returnFocusToSteam` → no-ops
- Overrides `isInstanceRunning` to skip 180s grace period (just `kill -0 $pid`)
- Calls `runDynamicSplitscreen` directly

**Usage:**
```
Terminal 1: python3 test-virtual-controller.py   # a=add r=remove q=quit
Terminal 2: ./tools/test-dynamic-mode.sh
```
Kill a mock instance PID to simulate Minecraft crash; use r/a to disconnect/reconnect.

**Note:** `assignControllerToSlot` is mocked — controller-to-instance mapping (Issue #9) is
NOT tested by this harness yet. Needs a follow-up to un-mock it and verify Controllable
config JSON files are written correctly.

### README: Known Limitations section added
Documents the identical-controller GUID limitation: SDL2 GUIDs are based on vendor+product ID,
so two controllers of the same model are indistinguishable. Workaround: use mixed controller
models. Added a cross-reference in Troubleshooting.

### Controllable mod upstream research
- Repo: https://github.com/MrCrayfish/Controllable (MrCrayfish, 292 stars)
- Root cause confirmed: `SDL2ControllerManager.connectToBestGameController()` matches by
  10-field `DeviceInfo.equals()` including GUID. Identical models → same GUID → wrong device.
- PR #576 (controller index selection) open 11 months, zero maintainer response.
- Issue #578 confirms SDL2 enumeration order is non-deterministic — makes index-based approach unreliable.
- Device-path based fix not feasible upstream (SDL2 doesn't expose /dev/input paths cross-platform).
- **Decision:** no upstream PR, no fork for now. Current Python ctypes + selected_controllers.json
  approach is best available solution. Fork only if identical-controller complaints grow.

### .gitignore updated
Added `!tools/` and `!tools/**` whitelist entries (repo uses whitelist-only pattern).

## Commit
`9d238d3` — pushed to origin/main

## Open items from this session
- controller-to-instance mapping not covered by test harness (needs un-mocking assignControllerToSlot)
- Display mirroring to Mac not resolved (krfb/krdpserver requires portal confirmation dialog
  on the physical machine; opted for SSH log-only testing approach instead)
- Issue #11 (black placeholder window for 3-player layout) still open
- Issue #6 (detect previous installation) still open
- Issue #8 (MS account OAuth during install) still open
