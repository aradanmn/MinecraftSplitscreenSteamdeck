---
name: Dynamic Splitscreen — Screen Resize and Reconnect Bug Fixes
description: Two logic bugs fixed in dynamic mode: screen not resizing on disconnect, and reconnect not spawning new instance
type: project
---

## Bugs Fixed (2026-03-15, commit f167cd4)

### Bug 1 — Screen never resized when controller disconnected while game running
**Root cause:** `handleControllerChange` scale-down path (`slots_to_launch <= 0`) returned early without stopping the instance or calling `repositionAllWindows`. It relied entirely on `checkForExitedInstances` to detect game exits — but that function only runs AFTER `handleControllerChange` returns, and only detects exits once Java's PID goes dead (up to 60s grace period if Java never started).

**Fix:** In the scale-down path, iterate `INSTANCE_ACTIVE[]` and check `INSTANCE_CONTROLLER_DEVICE[slot]`. If the tracked `/dev/input/eventXX` device no longer exists on disk (`[ ! -e "$dev" ]`), stop that instance immediately via `stopInstance()` and call `repositionAllWindows()` for remaining players.

### Bug 2 — Reconnect didn't spawn a new instance after exit
**Root cause:** After `checkForExitedInstances` marked a slot stopped, `KNOWN_CONTROLLER_COUNT` stayed elevated (e.g. 2 — the old total including the exited player's controller). If the player then disconnect+reconnected within the 2-second polling window, the monitor saw count `2→1→2` between polls and emitted **no CONTROLLER_CHANGE events**. On reconnect, `slots_to_launch = 2 - 2 = 0` → no new instance.

**Fix:** In `checkForExitedInstances`, after marking exits and repositioning, sync `KNOWN_CONTROLLER_COUNT` down to `countActiveInstances()`. This ensures the next disconnect event (or reconnect after a visible disconnect) produces a positive `slots_to_launch`.

## Key State Variables (dynamic mode)
- `KNOWN_CONTROLLER_COUNT` — last count seen by `handleControllerChange`; used to compute `slots_to_launch = new_count - KNOWN`
- `INSTANCE_ACTIVE[]` — 1 if slot has a running game, 0 otherwise
- `INSTANCE_CONTROLLER_DEVICE[]` — `/dev/input/eventXX` path assigned to each slot; checked for device existence in scale-down
- `CURRENT_PLAYER_COUNT` — display/tracking only, not used for launch decisions

## Remaining known limitation
If a player exits gracefully (closes Minecraft) but **keeps controller connected**, and **never disconnects**, there is no automatic trigger to relaunch for them. They must disconnect+reconnect their controller to signal they want back in. This is intentional: immediate auto-relaunch on exit would be surprising if they meant to quit.
