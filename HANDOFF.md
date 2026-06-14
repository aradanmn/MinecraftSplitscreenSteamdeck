# Session Handoff — Minecraft Splitscreen Steam Deck

**Repo:** `aradanmn/MinecraftSplitscreenSteamdeck`
**Active branch:** `claude/elegant-bell-vdupw5`
**Last commit:** `082a0ff` — hardware test geometry + gameplay checklists

---

## What this project is

A shell launcher that lets multiple players play Minecraft simultaneously on a
Steam Deck using Steam's virtual gamepads (`28de:11ff`). Each player gets their
own Minecraft instance running inside a `bwrap` sandbox that can only see their
controller's `/dev/input` nodes. A splitscreen Forge mod reads a
`splitscreen.properties` file to know which screen quadrant to render into.

---

## Architecture

```
minecraftSplitscreen.sh        ← orchestrator (sources all modules, entry point)
modules/
  dock_detection.sh            ← DRM sysfs: handheld vs docked; watch_display_mode()
  controller_monitor.sh        ← enumerate 28de:11ff devices; udev monitor loop
  window_manager.sh            ← compute grid geometry; apply_layout() via xdotool
  instance_lifecycle.sh        ← spawn_instance() / teardown_instance() via bwrap
  watchdog.sh                  ← poll bwrap PIDs; emit SLOT_DIED to FIFO
```

### Key runtime paths

**Handheld mode** (1 player, built-in screen):
```
main() → handheld_flow()
  → spawn_instance(1, event_node, js_node)
  → while read FIFO:
      SLOT_DIED 1      → teardown + exit
      DISPLAY_MODE_CHANGE docked → teardown + docked_flow()
```

**Docked mode** (up to 4 players, external display):
```
main() → docked_flow()
  → start_controller_monitor docked &   (writes CONTROLLER_ADD/REMOVE to FIFO)
  → initial scan: spawn existing controllers
  → while read FIFO:
      CONTROLLER_ADD   → find free slot, spawn_instance()
      CONTROLLER_REMOVE → teardown_instance(slot)
      SLOT_DIED N      → teardown_instance(N)   ← crash recovery
      DISPLAY_MODE_CHANGE handheld → teardown_all + handheld_flow()
```

**Crash recovery** (watchdog):
```
start_watchdog() runs in background
  every 2s: for each active slot, kill -0 bwrap_pid
  if dead and not already reported → echo "SLOT_DIED N" >> $SPLITSCREEN_FIFO
  dedup: won't re-emit until orchestrator clears slot (active=false)
```

### IPC: the FIFO

- Path: `~/.local/share/PolyMC/splitscreen.fifo`
- Created by `main()` with `mkfifo`; `exec 9>"$FIFO"` holds write end open so readers never block on `open()`
- Messages (newline-delimited):
  - `CONTROLLER_ADD <event_node> <js_node> <vendor> <product>`
  - `CONTROLLER_REMOVE <event_node>`
  - `DISPLAY_MODE_CHANGE handheld|docked`
  - `SLOT_DIED <slot>`

### State file

- Path: `~/.local/share/PolyMC/splitscreen_state.json`
- Written atomically via `jq | tmp | mv`
- Schema:
```json
{
  "mode": "handheld|docked",
  "slots": {
    "1": { "active": true, "pid": 12345, "event_node": "/dev/input/event3",
           "js_node": "/dev/input/js0", "bwrap_pid": 12344 },
    "2": { "active": false, "pid": null, "event_node": null,
           "js_node": null, "bwrap_pid": null },
    ...
  }
}
```

### bwrap sandbox per instance

```bash
bwrap \
  --dev-bind / /                        # full host rootfs
  --dev /dev                            # fresh devtmpfs (clears all /dev)
  --dev-bind /dev/dri /dev/dri          # GPU access
  --dev-bind <event_node> <event_node>  # only this controller's event node
  --dev-bind <js_node>    <js_node>     # only this controller's joystick node
  -- env SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT="0x28DE/0x11FF" \
         SDL_JOYSTICK_DEVICE=<js_node> \
         ...
  PolyMC.AppImage -l latestUpdate-N -a PN \
      --jvm-args "-Dorg.lwjgl.opengl.Window.title=SplitscreenPN"
```

---

## Test suite

### Unit tests (49/49 passing — run anywhere, no hardware needed)

```bash
bash tests/test_dock_detection.sh       # T1.1–T1.8  (8)
bash tests/test_controller_monitor.sh   # T2.1–T2.9  (9)
bash tests/test_window_manager.sh       # T3.1–T3.9  (9)
bash tests/test_instance_lifecycle.sh   # T4.1–T4.8  (8)
bash tests/test_watchdog.sh             # T5.1–T5.7  (7)
bash tests/test_orchestrator.sh         # T6.1–T6.8  (8, includes integration)
```

**T6.8** is the integration test — it runs a real `start_watchdog` and a real
`docked_flow` concurrently using a temp FIFO, kills a real process to get a dead
PID, and verifies the full pipeline fires: watchdog detects dead bwrap → writes
`SLOT_DIED` to FIFO → `docked_flow` reads it → calls `teardown_instance`.

Key testing patterns:
- All function mocks defined **inside subshells** `(...)` to prevent global scope pollution
- FIFOs held open with `exec 9<>"$fifo"` so reads/writes never block
- `WATCHDOG_POLL_INTERVAL_S=0.1` override for fast tests
- State files use temp dirs with `trap 'rm -rf "$tmpdir"' RETURN`

### Hardware tests (operator-guided, run on real Steam Deck via SSH)

```bash
cd tests/hardware
bash run_all.sh              # all stages 0–5
bash run_all.sh stage2       # single stage
```

Log file: `~/splitscreen-hwtest-YYYYMMDD_HHMMSS.log`

**Stage 0** — prereqs (automated): bwrap, jq, xdotool, python3, busctl, bc, PolyMC, Steam, display  
**Stage 1** — module smoke tests (automated): calls real module functions on real hardware  
**Stage 2** — handheld (human+automated):
  - Automated: slot state, bwrap liveness, window geometry via xdotool, splitscreen.properties
  - Human: 7-item gameplay checklist (rendering, controls, audio, frame rate)

**Stage 3** — docked hot-plug (human+automated):
  - Automated: per-slot window geometry at every layout change, splitscreen.properties per slot
  - Human: gameplay checklists at 1/2/3/4 player layouts; sticky slot verification

**Stage 4** — controller isolation (human+automated):
  - Automated: bwrap `/dev/input` fd count (expect 2 unique devices per instance)
  - Human: cross-input check (press button on P2's controller while in P1's Controls screen)

**Stage 5** — crash recovery (mostly automated):
  - Automated: kill Java PID → wait 30s for watchdog to clear slot
  - Automated: kill bwrap PID directly → same
  - Human: confirm placeholder appears; confirm slot reuse after plug-in

### New helpers added (tests/hardware/lib/helpers.sh)

- `hw_get_screen_resolution()` — xdpyinfo/xrandr, falls back to 1280×800
- `hw_expected_slot_geometry SLOT ACTIVE_SLOTS SW SH` — computes X Y W H
- `hw_assert_window_at LABEL TITLE EX EY EW EH [TOL]` — xdotool geometry check
- `hw_assert_splitscreen_properties LABEL SLOT EXPECTED_MODE` — reads properties file
- `hw_checklist TITLE ITEM...` — per-item y/n/s operator confirmation

---

## Current state / what's done

All 6 phases of the rewrite are complete and passing:
- Phase 1: dock_detection module
- Phase 2: controller_monitor module
- Phase 3: window_manager module
- Phase 4: instance_lifecycle module
- Phase 5: orchestrator rewrite (dynamic event loop)
- Phase 6: watchdog + handheld↔docked hot-swap

The hardware test suite is written and validated for syntax.
**The suite has NOT been run on physical hardware yet.**

---

## What to do next

The natural next step is to SSH into the Steam Deck and run the hardware tests:

```bash
ssh deck@<DECK_IP>
cd ~/MinecraftSplitscreenSteamdeck
git pull origin claude/elegant-bell-vdupw5

# Verify unit tests pass on the Deck
bash tests/test_dock_detection.sh
bash tests/test_controller_monitor.sh
bash tests/test_window_manager.sh
bash tests/test_instance_lifecycle.sh
bash tests/test_watchdog.sh
bash tests/test_orchestrator.sh

# Run hardware tests (requires desktop session, display, controllers)
DISPLAY=:0 bash tests/hardware/run_all.sh 2>&1 | tee ~/hw-test-run.log
```

Expected failures to investigate:
1. `bwrap --dev-bind /dev/dri` — if `/dev/dri` doesn't exist or isn't readable
2. `splitscreen.properties` mode values — depends on the exact Controlify/splitscreen mod version
3. Window geometry tolerance — 50px may need tuning depending on compositor/WM
4. `bc` missing — some SteamOS images don't have it; may need `sudo pacman -S bc`

---

## Key files

| File | Purpose |
|------|---------|
| `minecraftSplitscreen.sh` | Orchestrator entry point |
| `modules/watchdog.sh` | Crash recovery — poll bwrap PIDs |
| `modules/instance_lifecycle.sh` | spawn_instance / teardown_instance |
| `modules/window_manager.sh` | Grid geometry + xdotool layout |
| `modules/controller_monitor.sh` | udev + 28de:11ff enumeration |
| `modules/dock_detection.sh` | DRM sysfs connector detection |
| `tests/test_orchestrator.sh` | Integration test T6.8 (full crash pipeline) |
| `tests/hardware/run_all.sh` | Hardware test entry point |
| `tests/hardware/lib/helpers.sh` | hw_assert_window_at, hw_checklist, etc. |

---

## Gotchas / non-obvious decisions

1. **FIFO write-end must be held open** — `exec 9>"$FIFO"` in `main()` prevents
   `docked_flow`'s `while read` from getting EOF when all other writers close.
   `exec 9>&-` in `cleanup()` closes it. Tests use `exec 9<>"$fifo"` (R+W) for
   the same reason.

2. **BASH_SOURCE guard** — `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`
   at the bottom of the orchestrator allows test files to `source` it without
   triggering startup. All top-level code is inside `main()`.

3. **Mocks must be inside subshells** — In `test_orchestrator.sh`, function mocks
   defined at the outer scope of a test function persist globally. T6.3–T6.5
   define all mocks inside `(...)` subshells to prevent them overwriting the real
   `docked_flow` for T6.8.

4. **`_WATCHDOG_REPORTED` is an associative array** — declared with `declare -A`
   in `watchdog.sh` at module load time. Subshells inherit it, so the watchdog
   subshell starts with an empty dedup cache (correct).

5. **Slot numbers are sticky** — when a controller disconnects, its slot number is
   preserved. The vacated slot gets a black placeholder window. When that same
   controller reconnects, it reclaims the same slot (slot assignment is by
   event_node lookup in the CONTROLLER_REMOVE handler).
