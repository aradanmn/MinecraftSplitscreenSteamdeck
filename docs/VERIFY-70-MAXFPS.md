# On-Deck verification — #70 dynamic maxFps → display refresh

Branch: `claude/dynamic-maxfps-displays-bc9yoq`

## What this verifies

Each Minecraft instance's `maxFps` is now set at **launch time** to the **current
refresh** of the connected display, instead of the old hard-coded `maxFps:120`.
The value is sampled once in the **host** context (before the nested session
starts), carried across the re-exec, and written into every slot's `options.txt`
by `spawn_instance`.

**The single thing that could not be checked off-Deck:** does the probe return the
*real* panel refresh in **Game Mode**? The outer gamescope context is not a KDE
session, so `kscreen-doctor` is skipped and only `xrandr` runs against gamescope's
XWayland — which *may* report a synthetic mode. The code degrades safely (fallback
60 Hz, override `MCSS_MAX_REFRESH_HZ`), but Check 1 below is what tells us whether
detection genuinely works in Game Mode or falls back. **That detected Game-Mode
value is the number to report back.**

Expected refresh: Deck LCD → **60**, Deck OLED → **90**, docked external → its rate.

---

## Setup (Deck's own checkout)

The launcher runs from the deployed tree under `~/.local/share/PolyMC/`, not the
checkout — `git pull` alone is **not** a deploy.

```bash
cd ~/MinecraftSplitscreenSteamdeck
git fetch origin
git checkout claude/dynamic-maxfps-displays-bc9yoq
git pull --ff-only
./deploy.sh            # syncs launcher + runtime modules into ~/.local/share/PolyMC/
./deploy.sh --check    # optional: confirm the deployed tree matches the checkout
```

---

## Check 1 — probe sanity (no launch)

Run this **twice**: once in **Desktop Mode** (KDE — `kscreen-doctor` answers, the
trustworthy baseline) and once in **Game Mode** (gamescope — the real target).

```bash
cd ~/MinecraftSplitscreenSteamdeck
export DISPLAY=:0                       # the outer/host X server
source modules/runtime_context.sh
echo "--- raw probe (name enabled WxH refresh_hz) ---"
mcss_query_displays kscreen-doctor xrandr
echo "--- detected cap ---"
mcss_detect_max_refresh
```

**Expected:**
- Raw probe lists `eDP-1` (and any external) as `enabled` with a 4th field that is
  the real refresh — e.g. `eDP-1 enabled 1280x800 60` (LCD) / `... 90` (OLED).
- `mcss_detect_max_refresh` prints the **max** enabled refresh (60 / 90 / external).

**Record the Game-Mode result specifically.** If the raw probe shows no refresh
(4th field `-` or empty) and the detected value is `60`, detection fell back to the
default — note this: the cap is still safe on a 60 Hz LCD but it means the Game-Mode
probe didn't truly read the panel, and we may add a DRM-sysfs refresh path before
merging.

Sanity extras (optional):
```bash
MCSS_MAX_REFRESH_HZ=90 mcss_detect_max_refresh   # → 90 (explicit override honored)
MCSS_MAX_REFRESH_HZ=999 mcss_detect_max_refresh  # → 360 (clamped to ceiling)
```

---

## Check 2 — production launch writes the cap

Launch normally via the **Steam shortcut** (the `launchFromPlasma` production path —
this is where the host refresh is sampled; the bare `testNested` harness is not).
Play far enough that all your instances have spawned, then inspect the log + files:

```bash
# newest debug log (override path is $SPLITSCREEN_DEBUG_LOG if the launcher set one)
LOGF="$(ls -t /tmp/splitscreen-debug-*.log 2>/dev/null | head -1)"; echo "log: $LOGF"

# host sample + per-slot cap lines
grep -E 'max refresh=|Capped maxFps=' "$LOGF"

# the actual value written into each instance
grep -H '^maxFps:' ~/.local/share/PolyMC/instances/latestUpdate-*/.minecraft/options.txt
```

**Expected:**
- Log shows `[launchFromPlasma] max refresh=NHz` and one
  `[spawn_instance] Capped maxFps=N for slot X` per active slot.
- Every `options.txt` shows `maxFps:N`, where **N == the Check-1 detected value**,
  and the `maxFps:` key sits at column 0 (no leading spaces).

---

## Check 3 — visual (the eyeball step)

Enable the Steam **Quick Access → Performance → frame rate** counter (or the full
performance overlay). Confirm in-game FPS now **caps at the panel refresh** (≈60/90)
instead of the previous 300–600 fps. This is the thermal/CPU-headroom win from #70.

---

## Check 4 — docked external monitor (if available)

Dock to an external display at a different refresh (e.g. 120/144 Hz), relaunch, and
repeat Check 1 + Check 2. **Expected:** detected value and every `options.txt maxFps`
track the external monitor's refresh.

---

## Check 5 — master switch off

Confirm the feature can be disabled and does not clobber the baked default:

```bash
MCSS_CAP_FPS_TO_REFRESH=0 <launch via the same Steam shortcut / entry>
grep -H '^maxFps:' ~/.local/share/PolyMC/instances/latestUpdate-*/.minecraft/options.txt
```

**Expected:** `maxFps:120` (the baked pre-launch placeholder) is left untouched — no
`Capped maxFps=` lines in the log.

---

## Record results

| # | Check | Mode | Expected | Observed | Pass? |
|---|-------|------|----------|----------|-------|
| 1 | probe sanity | Desktop | 60 (LCD) / 90 (OLED) | | |
| 1 | probe sanity | **Game Mode** | real refresh, not fallback | | |
| 2 | options.txt == detected | Game Mode | maxFps:N per slot | | |
| 3 | fps overlay caps at refresh | Game Mode | ≈60/90, not 300–600 | | |
| 4 | docked tracks external | Docked | maxFps == external rate | | |
| 5 | switch off keeps 120 | Game Mode | maxFps:120 untouched | | |

Report back the **Game-Mode Check-1 value** above all — it decides whether the
xrandr-under-gamescope probe is sufficient or needs a DRM-sysfs refresh fallback
before this merges.

## Env knobs (reference)

| Var | Default | Effect |
|-----|---------|--------|
| `MCSS_CAP_FPS_TO_REFRESH` | `1` | Master switch; `0` keeps the baked `maxFps:120`. |
| `MCSS_MAX_REFRESH_HZ` | *(unset)* | Force a specific cap; also the host→nested cache. Still clamped. |
| `MCSS_MAX_REFRESH_FALLBACK_HZ` | `60` | Used when no display answers. |
| `MCSS_MAX_REFRESH_FLOOR_HZ` / `_CEIL_HZ` | `30` / `360` | Clamp bounds. |
