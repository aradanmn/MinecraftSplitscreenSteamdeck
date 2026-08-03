# A/B Benchmark Runbook — baseline vs. standard mod set + JVM flags

**What this measures:** whether the `claude/standard-install-mods-yfox41` changes
(required perf mods: Sodium, Lithium, FerriteCore, ModernFix-mVUS, Entity Culling,
ImmediatelyFast + Aikar-style JVM GC flags) actually improve FPS, memory headroom,
and smoothness at 1–4 concurrent players on a 16GB Steam Deck — before merging to main.

**Who does what:** a Claude Code session (the **driver**) runs on/SSH'd into the Deck
from the repo checkout and executes this runbook top to bottom; the **human** plays the
game, plugs controllers, reads F3, and answers the driver's questions. The driver runs
`tests/benchmark/sampler.sh` in the background during every cycle and records results
incrementally into `$BENCH/RESULTS.md` (copied from `RESULTS-TEMPLATE.md`).

**Driver operating rules**
- Update RESULTS.md after **every** cycle, never batch at the end — a crash mid-run
  must not lose data.
- Never run destructive commands outside the explicit Phase B list, and never start
  the torch without the human literally typing `TORCH`.
- If a cycle fails (crash, missing slot, OOM), record it as a result — do not silently
  retry. One retry is allowed after diagnosis; note both attempts.
- All cycles run **docked** on the same external display at the same resolution.

---

## Phase 0 — Setup (once, before Phase A)

0. **Set `$BENCH` first — every path below depends on it.** From the repo checkout:

   ```bash
   cd /path/to/MinecraftSplitscreenSteamdeck
   export BENCH="$PWD/.workdir/benchmark"
   ```

   Benchmark output lives under the checkout's git-ignored `.workdir/`, not in
   `$HOME` (#122), so the whole run is cleared by one `rm -rf .workdir`. Export it
   in every shell you drive the run from — an unset `$BENCH` would silently write
   to `/phaseA/...` and fail. `tests/benchmark/*.sh` resolve the same root on
   their own, so they need no argument.

1. `mkdir -p $BENCH/{phaseA,phaseC}/{1p,2p,3p,4p} $BENCH/{mangohud,world-backup,options-backup,baseline-manifest,branch-manifest}`
2. `cp tests/benchmark/RESULTS-TEMPLATE.md $BENCH/RESULTS.md` and fill the
   run-metadata block (date, SteamOS version `cat /etc/os-release`, dock/display model +
   resolution `xrandr | grep '*'` from Desktop Mode, controller models).
3. Verify tools: `jq --version`, `command -v mangohud` (absence is fine — F3-only path).
4. Confirm the sampler works on this Deck:
   `bash tests/benchmark/sampler.sh run /tmp/sampler-smoke & sleep 5; bash tests/benchmark/sampler.sh stop /tmp/sampler-smoke; head -3 /tmp/sampler-smoke/sampler.csv`
   — expect populated `gpu_busy_pct` and `apu_temp_mc` columns on real Deck hardware.

## Phase A step 0 — Baseline inventory (BEFORE touching anything)

```
for n in 1 2 3 4; do
  d=~/.local/share/PolyMC/instances/latestUpdate-$n
  mkdir -p $BENCH/baseline-manifest/instance-$n
  ls -la "$d/.minecraft/mods" > $BENCH/baseline-manifest/instance-$n/mods.txt 2>&1
  cp "$d/instance.cfg" "$d/mmc-pack.json" $BENCH/baseline-manifest/instance-$n/ 2>/dev/null
done
```

Record in RESULTS.md: the baseline mod list, the **Minecraft version** (from
`mmc-pack.json` — this is the version-match control for Phase B), and whether
`instance.cfg` contains GC flags in `JvmArgs` (expected: **no**).

## MangoHud probe (Phase A step 1; repeated as Phase B step 7)

1. `SINCE=$(date +%s); bash tests/benchmark/mangohud-ctl.sh enable 1`
2. Human: launch a **single instance** (handheld launch from the Steam shortcut, or
   docked with one controller), enter any world, play ~60s, quit fully.
3. `bash tests/benchmark/mangohud-ctl.sh probe-check $SINCE`
   - **PROBE PASS** → `bash tests/benchmark/mangohud-ctl.sh enable all`. MangoHud stays
     on for ALL cycles of BOTH phases (overlay overhead must be symmetric).
   - **PROBE FAIL** → `bash tests/benchmark/mangohud-ctl.sh disable all`. F3-only for
     BOTH phases. Do not block; record the verdict in RESULTS.md either way.

## World + settings standardization (Phase A, before the first cycle)

- Human creates world **`BenchWorld`** on Player 1's instance: **seed `4815162342`**,
  Creative, Normal difficulty, default world type, cheats ON. Enter it once, stand at
  spawn ~2 min (initial worldgen), then quit.
- Driver pins video settings identically in every instance (repeat after Phase B too):

```
for n in 1 2 3 4; do
  o=~/.local/share/PolyMC/instances/latestUpdate-$n/.minecraft/options.txt
  [ -f "$o" ] || continue
  sed -i -e 's/^renderDistance:.*/renderDistance:8/' \
         -e 's/^simulationDistance:.*/simulationDistance:8/' \
         -e 's/^enableVsync:.*/enableVsync:false/' \
         -e 's/^maxFps:.*/maxFps:260/' "$o"
done
cp ~/.local/share/PolyMC/instances/latestUpdate-*/.minecraft/options.txt $BENCH/options-backup/ 2>/dev/null || true
```

(If a setting key is absent — e.g. options.txt not yet generated — launch the instance
once to a menu, quit, and re-run the sed. Note: Sodium instances may also carry
`sodium-options.json`; leave it at defaults, just record it in the manifest.)

## Pre-flight — flight path scouting (once, before the first scored cycle)

**Why:** the flight bearings table below assumes every ~90s flight is "fast and
level" — uninterrupted. `BenchWorld` is a fixed seed (`4815162342`), so the
terrain along any given start-point + bearing is deterministic: it only needs
checking once, not once per cycle. This pass produces the **real** start
coordinates that replace the placeholder table further down.

**Roles, same as the rest of this runbook:** the driver (this session, SSH'd
into the Deck) creates virtual pads, injects teleport commands, and tracks
progress; the human pilots each flight and makes the "clear / blocked by a
mountain" call — the driver has no way to see the screen.

**Mechanism — read before starting, this is why the steps below are ordered
the way they are:**
- A virtual pad's `CONTROLLER_ADD` claims a slot by its own `phys_uniq`
  (`slot_claim`, `modules/slot_manager.sh`) and that slot stays claimed by
  that same identity for as long as the pad stays connected — so pads are
  created **first**, one at a time, and left running for the rest of the
  session. A different device (e.g. a physical controller used instead) can
  never resume into a slot it didn't originally claim.
- **No physical controller is connected at any point in this pass** — only
  virtual pads (for slot identity) plus a real mouse (for menu clicks). The
  mouse is invisible to `controller_monitor.sh`'s gamepad-capability gate, so
  clicking through menus never touches slot ownership.
- Teleports are injected by the driver via `hw_xdo xdotool` into **P1's**
  window (`SplitscreenP1` — P1 has cheats/op in `BenchWorld`), not typed by a
  human. Two rules from earlier benchmark sessions apply here too:
  1. **Space every `/tp` a couple of blocks apart per player** — never stack
     everyone at one point, even when only one player is actually flying.
  2. **Inject only in a hands-off window** — nobody's actively moving a stick.
     Racing live input can eat the command or fire it into the wrong context
     (an Escape once opened the pause menu mid-flight instead of reaching
     chat). Confirm "hands off" with the human before sending.
- Flight altitude in the existing bearing table is Y=120 — confirm this
  actually clears terrain during scouting rather than assuming it; Minecraft
  mountain peaks can exceed that in some biomes. Note the working altitude in
  the results table below, it doesn't have to stay 120 if a bearing needs more
  clearance.
- A scouting flight doesn't need the full ~90s a scored segment does — fly far
  enough in the bearing to be confident the terrain ahead is clear (or isn't),
  then turn back. Use the full duration if a stretch looks ambiguous.

**Stages — one player added at a time, session stays up the whole pass:**

Every player's bearing is different at every N (see the table below — P1 flies
`N` in the 1P cycle but `E` in the 2P cycle and `S` in the 3P cycle). So each
stage below re-checks *every currently-loaded* player's bearing for that
stage's N, not just the newly-added one.

0. **Setup once:** docked, external display connected, no physical
   controllers plugged in, a mouse connected. `BenchWorld` already exists (the
   world + settings standardization step above). Deploy latest code to the
   Deck if it isn't already current.
1. **1P stage — P1 only.**
   - `rig_create_pad 1` → slot 1 SPAWNs → instance 1 launches.
   - Mouse: open `BenchWorld`, Esc → Open to LAN (cheats on).
   - Hands-off window: driver `/tp`s P1 to a candidate start point for the 1P
     Phase A bearing (`N`). Human flies it, confirms clear or reports where it
     broke.
   - If blocked: adjust the start X/Z (keeping the bearing itself unchanged —
     see the earlier coordinate-axis note: X=east/west, Z=south/north, Y=up),
     re-inject, re-fly. Record the confirmed coordinate once clear.
   - Repeat for the 1P Phase C bearing (`NE`).
2. **2P stage — P2 joins.**
   - `rig_create_pad 2` → slot 2 SPAWNs → instance 2 launches.
   - Mouse: instance 2 → Multiplayer → LAN → join P1's game.
   - Hands-off window: driver `/tp`s P1 and P2 to their *2P-cycle* candidate
     points (spaced apart per the rule above) for Phase A (`E`, `W`). Human
     flies each one in turn (one screen at a time), confirms or adjusts.
   - Repeat for Phase C (`SE`, `NW`).
3. **3P stage — P3 joins.** Same pattern: `rig_create_pad 3`, mouse-join LAN,
   then scout all three players' 3P-cycle bearings — Phase A (`S`,
   `NE-far`, `SW-far`), Phase C (`SW`, `N-far`, `E-far`). The `-far` ones need
   an initial teleport out to unexplored territory before the bearing flight
   starts (same mechanism, just a bigger first hop) — see the existing `-far`
   footnote below for the shape of that.
4. **4P stage — P4 joins.** Same pattern: `rig_create_pad 4`, mouse-join LAN,
   scout all four players' 4P-cycle bearings — Phase A (`NW-far`, `SE-far`,
   `W-far`, `S-far`), Phase C (`NE-far`, `E-far2`, `S-far2`, `W-far2`).
5. **Teardown.** `rig_cleanup`, then the normal session-end steps from the
   test cycle protocol below.

**Output — fill in as you go, then fold the confirmed values into the flight
bearings table below (replacing the placeholder coordinates in its footnote):**

| N | Phase | Player | Bearing | Start X | Start Y | Start Z | Notes |
|---|---|---|---|---|---|---|---|
**New candidate area, 2026-08-02 (supersedes the earlier (0.5,160,-10)
candidate below it, which was never flown either)**: Scott reloaded and
picked a fresh central point, **(-2, 94, -58)**, with each player starting
one block away from it and flying at **Y=160**. Per-player offsets used
below: P1 (-2,160,-59) [north of center], P2 (-1,160,-58) [east], P3
(-2,160,-57) [south], P4 (-3,160,-58) [west] — spaced 1 block from center
each, picked to keep the "space players apart" rule satisfied without
guessing at exact numbers Scott didn't specify. **None of this has been
flown/confirmed yet** — every row below is a candidate, not a result.

| N | Phase | Player | Bearing | Start X | Start Y | Start Z | Notes |
|---|---|---|---|---|---|---|---|
| 1P | A | P1 | N | -2 | 160 | -59 | **Confirmed clear 2026-08-02** (~6s scouting flight, no obstructions). Facing yaw 180. |
| 1P | C | P1 | NE | -2 | 160 | -59 | **Confirmed clear 2026-08-02** (~6s scouting flight, no obstructions). Facing yaw 225. |
| 2P | A | P1 | E | -2 | 160 | -59 | **Confirmed clear 2026-08-03** (~6s flight, no obstructions) |
| 2P | A | P2 | W | -3 | 160 | -58 | **Confirmed clear 2026-08-03.** Start X corrected from -1 to -3 (west of P1, not east) — the original -1 start had P2 flying W back through/past P1's position instead of away from it, since P1's E bearing and P2's W bearing point at each other when P2 starts east of P1. Applies to both 2P rows below too (Phase C's SE/NW pair has the same geometry). |
| 2P | C | P1 | SE | -2 | 160 | -59 | **Confirmed clear 2026-08-03** (~6s flight, no obstructions) |
| 2P | C | P2 | NW | -3 | 160 | -58 | **Confirmed clear 2026-08-03.** Same corrected start X=-3 as the Phase A row above — NW bearing continues away from P1's SE bearing from this position. |
| 3P | A | P1 | S | 20000 | 160 | 19999 | **Confirmed clear 2026-08-03.** All 3 players `/tp @a 20000 160 20000` together first (not just the `-far` ones — the footnote's `@a` moves everyone, so P1's S bearing also flies from the far region), then respaced 1 block apart and faced per bearing. |
| 3P | A | P2 | NE-far | 20001 | 160 | 20000 | **Confirmed clear 2026-08-03.** Same far-teleport as the P1 row above. |
| 3P | A | P3 | SW-far | 19999 | 160 | 20000 | **Confirmed clear 2026-08-03.** Same far-teleport as the P1 row above. |
| 3P | C | P1 | SW | 40000 | 160 | 40001 | **Confirmed clear 2026-08-03.** All 3 players `/tp @a 40000 160 40000` together (new region, distinct from Phase A's), then respaced/faced per bearing. |
| 3P | C | P2 | N-far | 39999 | 160 | 40000 | **Confirmed clear 2026-08-03.** Same far-teleport as the P1 row above. |
| 3P | C | P3 | E-far | 40000 | 160 | 39999 | **Confirmed clear 2026-08-03.** Same far-teleport as the P1 row above. |
| 4P | A | P1 | NW-far | -20000 | 160 | -20001 | **Confirmed clear 2026-08-03.** All 4 players `/tp @a -20000 160 -20000` together, then respaced 1 block apart and faced per bearing. |
| 4P | A | P2 | SE-far | -19999 | 160 | -20000 | **Confirmed clear 2026-08-03.** Same far-teleport as the P1 row above. |
| 4P | A | P3 | W-far | -20000 | 160 | -19999 | **Confirmed clear 2026-08-03.** Same far-teleport as the P1 row above. |
| 4P | A | P4 | S-far | -20001 | 160 | -20000 | **Confirmed clear 2026-08-03.** Same far-teleport as the P1 row above. |
| 4P | C | P1 | NE-far | -40000 | 160 | -40001 | **Confirmed clear 2026-08-03.** All 4 players `/tp @a -40000 160 -40000` together (new region, distinct from Phase A's), then respaced/faced per bearing. |
| 4P | C | P2 | E-far2 | -39999 | 160 | -40000 | **Confirmed clear 2026-08-03.** Same far-teleport as the P1 row above. |
| 4P | C | P3 | S-far2 | -40000 | 160 | -39999 | **Confirmed clear 2026-08-03.** Same far-teleport as the P1 row above. |
| 4P | C | P4 | W-far2 | -40001 | 160 | -40000 | **Confirmed clear 2026-08-03.** Same far-teleport as the P1 row above. |

**Superseded candidate (never flown, kept for reference only):** 1P/A and
1P/C at (0.5, 160, -10) — proposed 2026-08-02 to dodge the (0,0) water
hazard by moving Z, but abandoned in favor of the fresh central point above
before ever being test-flown.

## Test cycle protocol (identical for every N and both phases)

Cycle = `<phase>/<N>p`, e.g. `phaseA/2p`. `OUT=$BENCH/<phase>/<N>p`.

1. **Prepare players.** Docked. Human plugs in exactly N controllers. Launch via the
   Steam shortcut. Slot 1 opens `BenchWorld` → Esc → **Open to LAN** (cheats on);
   slots 2..N join via Multiplayer → LAN. Everyone gathers at world spawn.
2. **Verify slot count** (driver): all N slots active, java PIDs live —
   `jq '.slots[] | select(.active==true) | .pid' ~/.local/share/PolyMC/splitscreen_state.json`
   If count ≠ N: fix (re-plug controller) before starting the clock.
3. **Start sampling:** `bash tests/benchmark/sampler.sh run "$OUT" &` (background).
4. **Segments** — driver marks each boundary and tells the human what to do:
   - `bash tests/benchmark/sampler.sh mark "$OUT" settle` → 180s: everyone stands at
     spawn doing nothing (JIT warmup + chunk load; not scored).
   - `mark "$OUT" S1_idle` → 120s: all players stand still at spawn, **facing north,
     F3 open**. Human notes each screen's FPS.
   - `mark "$OUT" S2_flight` → 180s: chunk-generation load. Each player creative-flies
     fast and level in their assigned bearing (table below) for ~90s, then turns around
     and flies back. Human notes the WORST FPS seen per screen.
   - `mark "$OUT" S3_idle2` → 60s: stand still again wherever you are (post-load steady
     state).
   - `mark "$OUT" end`
5. **Stop sampling:** `bash tests/benchmark/sampler.sh stop "$OUT"`
6. **Ask the human** (verbatim, one question set per cycle; record answers in
   RESULTS.md before anything else):
   1. "Approximate F3 FPS on each screen during the standing segment (one number per
      player, e.g. P1=60 P2=45)?"
   2. "Worst F3 FPS you saw on each screen during the flight segment?"
   3. "Overall smoothness this cycle, 1 (unplayable) to 5 (perfectly smooth)?"
   4. "Stutters/freezes/hitches: none, occasional, or frequent? Where?"
   5. "Any audio crackling or controller input lag? (yes/no + notes)"
   6. "Anything else abnormal?"
7. **Teardown + hygiene:** all players quit to title (session self-terminates). Driver
   verifies: `pgrep -f latestUpdate-` empty; state file slots all inactive;
   `sudo dmesg | grep -i -e oom -e "out of memory"` (or `journalctl -k | grep -i oom`
   if dmesg needs root) — record any hit; grep the session debug log
   (`/tmp/splitscreen-debug-latest.log`) for `SLOT_DIED`. 60s cool-down before the
   next cycle.
8. **Summarize:** `bash tests/benchmark/summarize.sh "$OUT"` → paste the segment lines
   into RESULTS.md.

### Flight bearings (fresh, ungenerated chunks every cycle)

| Cycle | Phase A bearings (P1..PN) | Phase C bearings (P1..PN) |
|---|---|---|
| 1P | N | NE |
| 2P | E, W | SE, NW |
| 3P | S, NE-far*, SW-far* | SW, N-far*, E-far* |
| 4P | NW-far*, SE-far*, W-far*, S-far* | NE-far*, E-far2*, S-far2*, W-far2* |

\* "far": before starting the flight, teleport out to unexplored territory —
slot 1's player (cheats are on) runs e.g. `/tp @a 20000 120 20000` (Phase A 3P),
`/tp @a -20000 120 -20000` (Phase A 4P), `/tp @a 40000 120 40000` (Phase C 3P),
`/tp @a -40000 120 -40000` (Phase C 4P) — then everyone flies their bearing from
there. This guarantees every flight generates brand-new chunks (worldgen load, not
chunk-cache reload) despite reusing the same world.

## Phase A — Baseline (existing install, as-is)

0. Inventory (above). 1. MangoHud probe. 2. World + settings standardization.
3–6. Cycles `phaseA/1p` → `2p` → `3p` → `4p` per the protocol.
7. **Back up the world + options** (MUST happen before Phase B):
   `cp -r ~/.local/share/PolyMC/instances/latestUpdate-1/.minecraft/saves/BenchWorld $BENCH/world-backup/`
   Verify: `du -sh $BENCH/world-backup/BenchWorld` is non-trivial (>1MB).

## Phase B — Torch + fresh install from the branch

1. **Pre-torch checklist** — driver verifies ALL, then asks the human to type `TORCH`:
   - [ ] `$BENCH/world-backup/BenchWorld` exists, >1MB
   - [ ] `baseline-manifest/` populated for all instances that existed
   - [ ] Phase A `sampler.csv`/`events.csv`/`summary.txt` present under `phaseA/*/`
   - [ ] RESULTS.md filled through Phase A
2. **Torch:** `cd <repo checkout> && ./uninstall-minecraft-splitscreen.sh`
   - "Keep my data?" → **`n`** (full wipe. keep-data preserves `instances/`, and a
     reinstall over surviving instances silently enters *update mode* — that would
     invalidate the fresh-install comparison)
   - "Are you sure…" → **`y`**
   - Verify: `~/.local/share/PolyMC` and `~/.local/share/PrismLauncher` are gone.
3. **Steam shortcut: leave it alone.** The uninstaller never removes it; it points at
   `~/.local/share/PolyMC/minecraftSplitscreen.sh`, which the reinstall recreates at
   the same path.
4. **Checkout the branch:**
   `git fetch origin claude/standard-install-mods-yfox41 && git checkout claude/standard-install-mods-yfox41 && git pull`
5. **Install:** `REPO_REF=claude/standard-install-mods-yfox41 ./install-minecraft-splitscreen.sh`
   (local checkout supplies modules/mods.conf/launcher; REPO_REF points the
   always-remote accounts.json/token.enc at the branch). Prompt answers:
   - Minecraft version → **the Phase A version** if listed as supported; otherwise
     accept latest and record the version delta as a CONFOUND in RESULTS.md.
   - Custom mods → `N`.  Steam integration → `N` (shortcut still exists).
     Desktop launcher → `N`.
6. **Restore world + settings:**
   `mkdir -p ~/.local/share/PolyMC/instances/latestUpdate-1/.minecraft/saves && cp -r $BENCH/world-backup/BenchWorld ~/.local/share/PolyMC/instances/latestUpdate-1/.minecraft/saves/`
   then re-run the options.txt pinning block (launch each instance to menu once first
   if options.txt doesn't exist yet).
7. **Re-run the MangoHud probe** (fresh instance.cfg reset the wrapper) — same
   PASS/FAIL handling; the choice must match Phase A's (both phases MangoHud, or both
   F3-only; if the verdicts differ, use F3-only for the comparison and note it).
8. **Branch inventory** to `$BENCH/branch-manifest/` (same commands as
   Phase A step 0). **Verify before proceeding:** each instance's `mods/` contains
   Sodium, Lithium, FerriteCore, ModernFix, EntityCulling, ImmediatelyFast (+
   Controlify + Fabric API); `instance.cfg` `JvmArgs` contains `-XX:+UseG1GC`. If
   either check fails, STOP — the A/B delta wouldn't measure what we think.

## Phase C — Branch benchmark

Cycles `phaseC/1p` → `2p` → `3p` → `4p`, identical protocol, Phase C flight bearings.

## Phase D — Comparison + merge decision

For each N: `bash tests/benchmark/summarize.sh $BENCH/phaseA/<N>p --compare $BENCH/phaseC/<N>p`
→ paste tables into RESULTS.md, then evaluate the gates:

**Hard gates — ALL must hold in Phase C, else NO merge:**
- 4P cycle completes with all 4 instances alive end-to-end; no oom-kill in
  dmesg/journal; no `SLOT_DIED` in the session log.
- 4P `rss_sum_max_mb` ≤ 12288 (12 GiB); `memavail_min_mb` ≥ 1024;
  `swap_delta_mb` < 256 per cycle; `psi_mem_full_max` < 5.
- FPS not worse than Phase A − 5%: per slot, per scored segment, per N — using
  MangoHud p50 when available, else the human F3 readings.
- No new failure class vs Phase A (crash, black screen, input loss, audio dropout).

**Soft gates — expected to hold; mixed results = documented maintainer call:**
- Smoothness rating ≥ Phase A at each N; stutter reports not worse.
- `apu_temp_max_c` not sustained >95°C; 4P per-slot CPU not pinned harder than baseline.

**Expected direction** (so anomalies stand out): S2_flight FPS + stutter should improve
most (Sodium/Lithium/ModernFix), RSS should drop (FerriteCore), startup should feel
faster (ModernFix). A regression in any of these deserves investigation, not hand-waving.

**Decision:** all hard + soft pass → merge the branch to main. Any hard gate fails →
no merge; record the failing metric + cycle in RESULTS.md and open an issue.

## Post-run recording (repo conventions)

- Summary tables + verdict → commit as `docs/BENCH-AB-<date>.md` on the branch.
- Dated "Validation run" block in `docs/SPEC.md` §3b — a 4P pass also formally closes
  the D6 item "4 instances run concurrently without OOM (RAM within budget)".
- MEMORY.md: flip the two 2026-07-17 entries' Status lines with the verdict.
- `sessions/SESSION-<date>.md`: narrative of the run.
- Raw CSVs stay on the Deck under `$BENCH/` (not committed).
