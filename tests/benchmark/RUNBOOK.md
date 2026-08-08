# A/B Benchmark Runbook — pre-#94 baseline vs. current main (standard mod set + JVM flags)

## What this measures

PR #94 (`claude/standard-install-mods-yfox41`; required perf mods Sodium, Lithium,
FerriteCore, ModernFix-mVUS, Entity Culling, ImmediatelyFast + Aikar-style JVM GC
flags) **already merged to `main` on 2026-07-18** and has shipped in every install
since. This runbook re-measures whether that change actually improves FPS, memory
headroom, and smoothness at 1–4 concurrent players on a 16GB Steam Deck.

**This is round 2, not the first measurement.** Round 1
(`docs/BENCH-AB-2026-07-18.md`, run 2026-07-17/18) already has a **MERGE verdict** —
that result is what PR #94 was actually merged on. Round 1 used a single human
blind-teleporting each player as a proxy for chunk-generation load, because one
person can't pilot 4 players' actual flight simultaneously. Round 2 exists because
the virtual-pad rig (`tests/lib/uhid_rig.sh`, #136) now makes genuine simultaneous
piloted flight possible — real chunk-load stress per player instead of a teleport
proxy. If you're re-deriving why this second run is needed, that's why; don't
re-litigate it.

**Because the change is already on `main`, "the existing install" is no longer a
valid baseline** — it already has the mods/flags. Both phases install from a
specific git ref instead: Phase A from commit `2d5d321` (main, immediately before
PR #94 merged), Phase C from current `main`/HEAD.

---

## Roles

| Role | Who | Does what |
|---|---|---|
| **Driver** | Claude, SSH'd into the Deck from the repo checkout | Runs every command, creates virtual pads (`rig_create_pad`) for player identity, injects `/tp` and menu-navigation input, samples metrics, records results, drives all install/uninstall prompts |
| **Human** | Scott, physically at the Deck | Pilots each flight, reads F3, answers the driver's questions, types `TORCH` to authorize a wipe, clicks through menus with a mouse |

**No physical controllers or keyboard are ever connected.** Only virtual pads (for
slot identity — `slot_claim` matches strictly by `phys_uniq`, so a real controller
used instead could never resume into a slot a virtual pad claimed) plus a real mouse
for menu clicks (invisible to `controller_monitor.sh`'s gamepad-capability gate, so
it never touches slot ownership). **Because there's no keyboard, the driver must
inject Escape via `hw_xdo` proactively before asking the human to quit to a menu —
don't wait for "I'm stuck."** Pattern:

```bash
line=$(pgrep -a Xwayland | grep -- '-auth' | grep -oE ':[0-9]+ -auth [^ ]+' | head -1)
export DISPLAY=$(cut -d' ' -f1 <<<"$line")
export XAUTHORITY=$(cut -d' ' -f3 <<<"$line")
WID=$(jq -r '.slots["<N>"].wid' ~/.local/share/PolyMC/splitscreen_state.json)
xdotool key --window "$WID" Escape
```

---

## Physical requirements — what needs Scott at the Deck, and when

| Sitting | Physical presence? | Why |
|---|---|---|
| **1 — Setup + Phase A install** (DONE) | No, except typing `TORCH` and answering a couple of install prompts (can be done remotely via chat) | Backup/torch/install/inventory are all driver-executed over SSH; nothing on-screen needs watching until the MangoHud probe |
| **1 — MangoHud probe** (DONE, part of sitting 1) | **Yes** | Needs eyes on the overlay + a mouse to navigate + ~60s of play |
| **2 — Phase A cycles (1P→4P)** | **Yes, the whole sitting** | Piloting every flight, reading F3, answering the question set each cycle |
| **3 — Phase B install + Phase C cycles** | **Yes, the whole sitting** | Same as sitting 2, plus `TORCH` confirmation for the reinstall |
| **4 — Phase D comparison + decision + docs** | **No** | Pure data analysis from CSVs already on the Deck; driver-only |

Every physical sitting needs: **docked**, external display connected, a mouse
connected, **no physical controllers, no keyboard**.

---

## Known gaps (carry these into every future benchmark, not just #70)

- **PolyMC's own binary is unpinned.** `download_prism_launcher()`
  (`modules/launcher_setup.sh`) always fetches `PolyMC/PolyMC/releases/latest`,
  independent of any git ref. Worse, the release's `target_commitish` is
  `"develop"` — a moving branch — so a tag like "7.1" can be silently rebuilt from
  a different commit without the version string changing. **Tag name alone is not
  a reliable fingerprint — always record the SHA256 too.** Exact build installed
  2026-08-04: `PolyMC-Linux-amd64-7.1.AppImage`, SHA256
  `b5e4c0aa15d691d0eb26fbec19e5e8794a57fcb6cc093b22b4b5885c52f82608`. Round 1
  (2026-07-17/18) almost certainly ran a different PolyMC build than round 2 —
  they are not comparable on launcher binary, only on Minecraft-side
  mods/flags/version. Get the current fingerprint after every install:
  ```bash
  curl -s https://api.github.com/repos/PolyMC/PolyMC/releases/latest | \
    jq -r '.assets[] | select(.name | test("linux-amd64.*\\.AppImage$";"i")) | "\(.name) \(.digest)"'
  ```
- **`REPO_REF` is required, not optional, whenever installing from a non-`main`
  ref.** `accounts.json` is fetched live from `${MCSS_REPO_RAW_URL}`, which
  defaults to `main` if `REPO_REF` is unset. A same-day-but-unrelated commit
  (`728013d`) renamed the account profile prefix `P`→`Player`; without pinning
  `REPO_REF` to the exact ref's full SHA, the installer fetches current-`main`'s
  accounts.json against older validation code and hard-fails before mod
  selection.
- **`get_supported_minecraft_versions()` queries live APIs at install time** — always
  explicitly select the exact MC version you need (never "accept latest"), and
  verify it's actually offered before assuming.

---

## Progress checkpoint

- [x] **Sitting 1** (2026-08-04/05): Phase 0 setup, Phase A step −1 (backup + torch +
      install pre-#94 baseline), Phase A step 0 (baseline inventory), MangoHud probe
      (PASS), world + settings standardization. **Nothing here needs redoing.**
- [~] **Sitting 2** (2026-08-08, partial): `phaseA/1p` **done** — data accepted
      (see caveats below). `2p`/`3p`/`4p` **not started**, pick up next sitting.
      Slot 1 torn down clean at end (no live processes, state file inactive,
      no leftover pad devices) — safe resume point, no recovery needed.
- [ ] **Sitting 3**: Phase B (torch + reinstall current `main`) + Phase C scored
      cycles — `phaseC/1p` → `2p` → `3p` → `4p`.
- [ ] **Sitting 4**: Phase D comparison, gate evaluation, merge/no-merge decision,
      post-run recording.

**`phaseA/1p` caveats (all discovered live 2026-08-08, fixed for future cycles
except the last):**
- Two aborted attempts before the accepted run: (1) mid-flight chat `/tp`
  turn-around left the chat box open, silently eating all movement input for
  the rest of the segment; (2) redo script never called `sampler.sh run`, so
  no metrics were captured despite correct timing. Both fixed in the protocol
  above (RX-based turn, not chat) and in tooling discipline (verify the
  sampler is actually running before trusting a "clean" script exit).
- **RX-turn/camera drift, still unexplained.** Calibrated 1.0s right-stick
  hold ≈ 170-180° turn when tested in isolation (both standing and airborne,
  confirmed via exact F3 yaw readings). But across all three attempts, the
  actual scored flight ended up displaced far more on the X axis than a
  clean north/south out-and-back should ever produce — suggests the virtual
  pad's RX "neutral" (128) isn't a true center and the camera drifts slowly
  throughout ordinary forward flight, not just during the deliberate turn.
  **Decided to accept anyway**: the metrics that matter (FPS/CPU/GPU/memory
  under sustained active flight) don't depend on the flight path being a
  clean reciprocal line, and the actual displacement (hundreds of blocks)
  is nowhere near 2P/3P/4P's bearing offsets (20000+/40000+), so no
  collision risk with future cycles' fresh-chunk assumptions. Root cause
  not investigated further — if it matters later, start there.
- **`inactivityFpsLimit` — required fix, applied to all 4 instances.** MC's
  "Reduce FPS when: AFK" option throttled idle-segment FPS to ~30 regardless
  of actual capability, making the idle segment meaningless until set to
  `"minimized"` (only reduces FPS when the window is literally minimized,
  which never happens here). Now baked into the settings-standardization
  block (Sitting 1 step 13) for future installs.
- **`summarize.sh`'s MangoHud percentile calc was O(n²)** (an insertion sort
  sized for an assumed ~10 samples/s) — hung for minutes against a real
  ~49k-row MangoHud CSV (native frame rate, not throttled). Fixed to an
  external `sort -n` pipeline; verified against the same file post-fix.

Before resuming any sitting: `git pull` the Deck checkout, and check current
rig/slot state (`rig_list_pads`, `pgrep -fal latestUpdate-`, the state file) rather
than assuming a clean start.

---

## Sitting 1 — Setup + Phase A install (reference; already done)

Kept for reproducibility — do **not** repeat unless the install itself needs
redoing (e.g. Phase A's instances got corrupted).

1. **`$BENCH` first** — every path below depends on it:
   ```bash
   cd /path/to/MinecraftSplitscreenSteamdeck
   export BENCH="$PWD/.workdir/benchmark"
   ```
   Lives under the checkout's git-ignored `.workdir/` (#122) — the whole run is
   cleared by one `rm -rf .workdir`, and nothing under it is committed.
2. `mkdir -p $BENCH/{phaseA,phaseC}/{1p,2p,3p,4p} $BENCH/{mangohud,world-backup,options-backup,baseline-manifest,branch-manifest}`
3. `cp tests/benchmark/RESULTS-TEMPLATE.md $BENCH/RESULTS.md`, fill run-metadata
   (date, SteamOS version, dock/display model+resolution, input method = virtual
   pads only, PolyMC tag+SHA256 per the known-gaps note above).
4. Verify tools (`jq --version`, `command -v mangohud`); sampler smoke test:
   `bash tests/benchmark/sampler.sh run /tmp/sampler-smoke & sleep 5; bash tests/benchmark/sampler.sh stop /tmp/sampler-smoke; head -3 /tmp/sampler-smoke/sampler.csv`
   — expect populated `gpu_busy_pct`/`apu_temp_mc` columns.
5. **Back up whatever world already exists** before touching anything:
   `cp -r ~/.local/share/PolyMC/instances/latestUpdate-1/.minecraft/saves/BenchWorld $BENCH/world-backup/`
   — skip only if no world exists yet. Verify non-trivial size (>1MB).
6. **Torch** (human types `TORCH` first): `./uninstall-minecraft-splitscreen.sh` →
   "Keep my data?" **`n`** → "Are you sure?" **`y`**. Verify
   `~/.local/share/PolyMC` and `~/.local/share/PrismLauncher` are gone. The Steam
   shortcut survives untouched (points at a path the reinstall recreates).
7. **Checkout the pre-#94 baseline ref**: `git fetch origin && git checkout 2d5d321`
   (detached HEAD — commit yourself into nothing here).
8. **Install**:
   `REPO_REF=2d5d32113a2bc29be572f5543512dd3b78f2391e ./install-minecraft-splitscreen.sh`
   — `REPO_REF` is mandatory (see known gaps). Prompt answers:
   - Minecraft version → explicitly select the version the backed-up world was
     saved in (26.2). Never "accept latest".
   - Mod selection → `-1` (required mods only — Controlify and its deps; a true
     pre-#94 baseline declines every optional QoL/Sodium-extra mod too).
   - Custom mods → `N`. Steam integration → `N`. Desktop launcher → `N`.
9. **Restore the world** (if step 5 backed one up):
   `mkdir -p ~/.local/share/PolyMC/instances/latestUpdate-1/.minecraft/saves && cp -r $BENCH/world-backup/BenchWorld ~/.local/share/PolyMC/instances/latestUpdate-1/.minecraft/saves/`
10. **Return the driver checkout to `main`**: `git checkout main && git pull --ff-only`
    — the benchmark tooling (`sampler.sh`, `mangohud-ctl.sh`) doesn't exist at
    `2d5d321`. The install already ran; switching the driver's own checkout back
    doesn't touch the installed instances.
11. **Baseline inventory** (`$BENCH/baseline-manifest/`, per instance:
    `ls -la mods/`, copy `instance.cfg` + `mmc-pack.json`). Record mod list, MC
    version, and confirm **no** GC flags in any `JvmArgs` — if found, `2d5d321`
    was checked out wrong; stop and re-verify.
12. **MangoHud probe** — physical sitting starts here:
    1. `SINCE=$(date +%s); bash tests/benchmark/mangohud-ctl.sh enable 1`
    2. Driver: `rig_create_pad 1`; human launches the Steam shortcut, enters any
       world (BenchWorld is fine), plays ~60s, quits (driver injects Escape).
    3. `bash tests/benchmark/mangohud-ctl.sh probe-check $SINCE` — PASS →
       `enable all` for both phases; FAIL → `disable all`, F3-only for both
       phases. Either way, record the verdict; do not block on it.
    4. `rig_cleanup`.
13. **World + settings standardization**: world already restored with cheats on
    (skip creation). Pin video settings identically across all 4 instances:
    ```bash
    for n in 1 2 3 4; do
      o=~/.local/share/PolyMC/instances/latestUpdate-$n/.minecraft/options.txt
      [ -f "$o" ] || continue
      sed -i -e 's/^renderDistance:.*/renderDistance:8/' \
             -e 's/^simulationDistance:.*/simulationDistance:8/' \
             -e 's/^enableVsync:.*/enableVsync:false/' \
             -e 's/^maxFps:.*/maxFps:260/' \
             -e 's/^inactivityFpsLimit:.*/inactivityFpsLimit:"minimized"/' "$o"
      grep -q '^inactivityFpsLimit:' "$o" || echo 'inactivityFpsLimit:"minimized"' >> "$o"
    done
    cp ~/.local/share/PolyMC/instances/latestUpdate-*/.minecraft/options.txt $BENCH/options-backup/ 2>/dev/null || true
    ```

---

## Sitting 2 — Phase A scored cycles

**Physical, the whole sitting.** Docked, mouse only, no controllers/keyboard.

Before starting: confirm rig/slot state is clean (nothing live from sitting 1).

Run the **Test cycle protocol** (below) four times: `phaseA/1p` → `2p` → `3p` →
`4p`, using the **Phase A bearings** from the flight-bearings table.

After the 4th cycle, **back up the world + options** (this supersedes sitting 1's
pre-cycle backup — it now captures the post-cycle state that Phase B/C restore
from):
```bash
cp -r ~/.local/share/PolyMC/instances/latestUpdate-1/.minecraft/saves/BenchWorld $BENCH/world-backup/
du -sh $BENCH/world-backup/BenchWorld   # verify non-trivial
```

---

## Sitting 3 — Phase B install + Phase C scored cycles

**Physical, the whole sitting.** Same setup as sitting 2.

### Phase B — torch + reinstall current `main`

1. **Pre-torch checklist** (driver verifies all, then human types `TORCH`):
   - [ ] `$BENCH/world-backup/BenchWorld` exists, >1MB (from end of sitting 2)
   - [ ] `baseline-manifest/` populated
   - [ ] Phase A `sampler.csv`/`events.csv`/`summary.txt` present under `phaseA/*/`
   - [ ] RESULTS.md filled through Phase A
2. **Torch**: same as sitting 1 step 6 (`n` then `y`).
3. **Return to current `main`**: `git checkout main && git fetch origin && git pull --ff-only`.
4. **Install**: `./install-minecraft-splitscreen.sh` (no `REPO_REF` needed — `main`
   is already the default and matches the checkout). Prompt answers:
   - Minecraft version → explicitly select the exact Phase A version (26.2). Never
     "accept latest"; if genuinely absent from the list, STOP rather than
     substitute silently.
   - Custom mods → `N`. Steam integration → `N`. Desktop launcher → `N`.
5. **Restore world + settings**: same restore command as sitting 1 step 9, then
   re-run the options.txt pinning block from sitting 1 step 13.
6. **Re-run the MangoHud probe** (fresh `instance.cfg` resets the wrapper) — same
   PASS/FAIL handling; the choice must match Phase A's verdict (both MangoHud, or
   both F3-only — if they differ, use F3-only for the comparison and note it).
7. **Branch inventory** to `$BENCH/branch-manifest/` (same commands as sitting 1
   step 11). **Verify before proceeding**: all 6 perf mods present in every
   instance's `mods/`, `JvmArgs` contains `-XX:+UseG1GC`. Either check failing →
   STOP, the A/B wouldn't measure what we think.

### Phase C — scored cycles

Run the **Test cycle protocol** four times: `phaseC/1p` → `2p` → `3p` → `4p`,
using the **Phase C bearings** from the flight-bearings table.

---

## Sitting 4 — Phase D comparison + decision + docs

**Driver-only, no physical presence needed.** Deck just needs to be reachable.

For each N: `bash tests/benchmark/summarize.sh $BENCH/phaseA/<N>p --compare $BENCH/phaseC/<N>p`
→ paste tables into RESULTS.md, then evaluate:

**Hard gates — ALL must hold in Phase C, else the change does not stand as validated:**
- 4P cycle completes with all 4 instances alive end-to-end; no oom-kill in
  dmesg/journal; no `SLOT_DIED` in the session log.
- 4P `rss_sum_max_mb` ≤ 12288 (12 GiB); `memavail_min_mb` ≥ 1024;
  `swap_delta_mb` < 256 per cycle; `psi_mem_full_max` < 5.
- FPS not worse than Phase A − 5%: per slot, per scored segment, per N — MangoHud
  p50 when available, else human F3 readings.
- No new failure class vs Phase A (crash, black screen, input loss, audio dropout).

**Soft gates — expected to hold; mixed results = documented maintainer call:**
- Smoothness rating ≥ Phase A at each N; stutter reports not worse.
- `apu_temp_max_c` not sustained >95°C; 4P per-slot CPU not pinned harder than
  baseline.

**Expected direction** (so anomalies stand out): S2_flight FPS + stutter should
improve most (Sodium/Lithium/ModernFix), RSS should drop (FerriteCore), startup
should feel faster (ModernFix). A regression in any of these deserves
investigation, not hand-waving.

**Decision:** all hard + soft pass → change stands validated on `main`, close #70.
Any hard gate fails → the already-shipped change has a real regression; record
the failing metric + cycle in RESULTS.md and open an issue (revert vs. fix-forward
is a maintainer call, not a merge decision, since it's already live).

**Post-run recording:**
- Summary tables + verdict → commit as `docs/BENCH-AB-<date>.md` directly on
  `main` (no branch to merge — this is retroactive validation of what's already
  shipped).
- Dated "Validation run" block in `docs/SPEC.md` §3b — a 4P pass also formally
  closes the D6 item "4 instances run concurrently without OOM (RAM within
  budget)".
- `docs/MEMORY.md`: flip the two 2026-07-17 entries' Status lines with the
  verdict.
- `sessions/SESSION-<date>.md`: narrative of the run.
- Raw CSVs stay on the Deck under `$BENCH/` (not committed).

---

## Test cycle protocol (used by sittings 2 and 3, identical both times)

Cycle = `<phase>/<N>p`, e.g. `phaseA/2p`. `OUT=$BENCH/<phase>/<N>p`.

1. **Prepare players.** `rig_create_pad 1` through `rig_create_pad N`, one at a
   time: slot 1 SPAWNs → instance 1 launches → mouse opens `BenchWorld` → Esc →
   **Open to LAN** (cheats on); each subsequent pad SPAWNs its slot → mouse joins
   that instance via Multiplayer → LAN. Everyone gathers at world spawn.
2. **Verify slot count** (driver): all N slots active, java PIDs live —
   `jq '.slots[] | select(.active==true) | .pid' ~/.local/share/PolyMC/splitscreen_state.json`
   If count ≠ N: `rig_create_pad` the missing slot(s) (resumes by `phys_uniq` if
   previously claimed this session) before starting the clock.
3. **Start sampling:** `bash tests/benchmark/sampler.sh run "$OUT" &` (background).
4. **Segments** — driver marks each boundary and tells the human what to do:
   - `sampler.sh mark "$OUT" settle` → 90s: everyone stands at spawn doing
     nothing (JIT warmup + chunk load; not scored).
   - `mark "$OUT" S1_idle` → 120s: all players stand still at spawn, facing
     north, F3 open. Human notes each screen's FPS. **Before this segment,
     disable any "reduce FPS when idle/AFK" option** — confirmed live
     2026-08-08 that MC throttles to ~30fps after a period with zero input,
     which would make this segment's reading meaningless as an idle-capacity
     measurement.
   - `mark "$OUT" S2_flight` → 180s: chunk-generation load. Each player
     creative-flies fast and level in their assigned bearing for ~90s, then
     turns around and flies back. Human notes the WORST FPS seen per screen.
     **Turn-around: use the virtual pad's right-stick (RX) to rotate, not a
     mid-flight `/tp`.** Confirmed live 2026-08-08: a chat-injected `/tp`
     between the two legs left the chat box open, silently eating all
     subsequent movement input for the rest of the segment (flew out, never
     flew back). Reserve `/tp` for the one-time precise pre-flight
     positioning (done in the hands-off window before scoring starts, not
     mid-segment).
   - `mark "$OUT" S3_idle2` → 60s: stand still again wherever you are.
   - `mark "$OUT" end`
5. **Stop sampling:** `bash tests/benchmark/sampler.sh stop "$OUT"`
6. **Ask the human** (verbatim, record answers in RESULTS.md before anything
   else):
   1. "Approximate F3 FPS on each screen during the standing segment (one number
      per player)?"
   2. "Worst F3 FPS you saw on each screen during the flight segment?"
   3. "Overall smoothness this cycle, 1 (unplayable) to 5 (perfectly smooth)?"
   4. "Stutters/freezes/hitches: none, occasional, or frequent? Where?"
   5. "Any audio crackling or controller input lag?"
   6. "Anything else abnormal?"
7. **Teardown + hygiene:** all players quit to title (driver injects Escape,
   mouse clicks quit; session self-terminates), then `rig_cleanup` (each cycle
   starts fresh — no pad carries over to the next N). Verify: `pgrep -f
   latestUpdate-` empty; state file slots all inactive; no leftover
   `uhid_pad.py`; `sudo dmesg | grep -i -e oom -e "out of memory"` (record any
   hit); grep session debug log for `SLOT_DIED`. 60s cool-down before the next
   cycle.
8. **Summarize:** `bash tests/benchmark/summarize.sh "$OUT"` → paste segment
   lines into RESULTS.md.

**Injection rules** (apply to every `/tp` the driver sends, both scouting and
scored cycles):
1. Space every `/tp` a couple of blocks apart per player — never stack everyone
   at one point.
2. Inject only in a hands-off window — nobody actively moving a stick. Racing
   live input can eat the command or misfire it (e.g. hitting a pause menu
   mid-flight instead of chat). Confirm "hands off" with the human before
   sending.

---

## Flight bearings (fresh, ungenerated chunks every cycle)

Scouted and confirmed clear 2026-08-02/03 — coordinates are seed-determined
(`BenchWorld`, seed `4815162342`), so they don't need re-checking as long as the
same world is reused.

| Cycle | Phase A bearings (P1..PN) | Phase C bearings (P1..PN) |
|---|---|---|
| 1P | N | NE |
| 2P | E, W | SE, NW |
| 3P | S, NE-far*, SW-far* | SW, N-far*, E-far* |
| 4P | NW-far*, SE-far*, W-far*, S-far* | NE-far*, E-far2*, S-far2*, W-far2* |

\* "far": before starting the flight, teleport everyone out to unexplored
territory first (`/tp @a X Y Z` moves ALL currently-loaded players, not just the
ones whose bearing is suffixed `-far` — every player in that stage flies from the
far region) — then respace ~1 block apart and face per bearing. This guarantees
every flight generates brand-new chunks despite reusing the same world.

| N | Phase | Player | Bearing | Start X | Start Y | Start Z | Notes |
|---|---|---|---|---|---|---|---|
| 1P | A | P1 | N | -2 | 160 | -59 | Facing yaw 180. |
| 1P | C | P1 | NE | -2 | 160 | -59 | Facing yaw 225. |
| 2P | A | P1 | E | -2 | 160 | -59 | |
| 2P | A | P2 | W | -3 | 160 | -58 | West of P1, not east — P2's bearing must point away from P1, not back through it. Applies to the Phase C SE/NW pair below too. |
| 2P | C | P1 | SE | -2 | 160 | -59 | |
| 2P | C | P2 | NW | -3 | 160 | -58 | |
| 3P | A | P1 | S | 20000 | 160 | 19999 | All 3 players `/tp @a 20000 160 20000` together first, then respaced/faced. |
| 3P | A | P2 | NE-far | 20001 | 160 | 20000 | Same far-teleport as the P1 row. |
| 3P | A | P3 | SW-far | 19999 | 160 | 20000 | Same far-teleport as the P1 row. |
| 3P | C | P1 | SW | 40000 | 160 | 40001 | All 3 players `/tp @a 40000 160 40000` (new region, distinct from Phase A's). |
| 3P | C | P2 | N-far | 39999 | 160 | 40000 | Same far-teleport as the P1 row. |
| 3P | C | P3 | E-far | 40000 | 160 | 39999 | Same far-teleport as the P1 row. |
| 4P | A | P1 | NW-far | -20000 | 160 | -20001 | All 4 players `/tp @a -20000 160 -20000` together. |
| 4P | A | P2 | SE-far | -19999 | 160 | -20000 | Same far-teleport as the P1 row. |
| 4P | A | P3 | W-far | -20000 | 160 | -19999 | Same far-teleport as the P1 row. |
| 4P | A | P4 | S-far | -20001 | 160 | -20000 | Same far-teleport as the P1 row. |
| 4P | C | P1 | NE-far | -40000 | 160 | -40001 | All 4 players `/tp @a -40000 160 -40000` (new region). |
| 4P | C | P2 | E-far2 | -39999 | 160 | -40000 | Same far-teleport as the P1 row. |
| 4P | C | P3 | S-far2 | -40000 | 160 | -39999 | Same far-teleport as the P1 row. |
| 4P | C | P4 | W-far2 | -40001 | 160 | -40000 | Same far-teleport as the P1 row. |

If a future re-scout is ever needed (different world, different seed): see
`tests/benchmark/RUNBOOK-20260805.md` for the full scouting procedure that
produced this table (pad-by-pad staged scouting, one player added at a time,
driver-injected `/tp` in hands-off windows) — not reproduced here since it's a
one-time-per-world cost, not part of the repeatable per-run protocol.
