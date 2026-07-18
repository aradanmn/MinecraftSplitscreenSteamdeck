# Benchmark Results — baseline vs. standard mod set + JVM flags

> Working copy lives at `~/mcss-benchmark/RESULTS.md` on the Deck. The driver fills it
> in **after every cycle**. After the run, the summary tables + verdict are committed
> to the repo as `docs/BENCH-AB-<date>.md` (see RUNBOOK.md "Post-run recording").

## Run metadata

| Field | Value |
|---|---|
| Date / driver session | |
| SteamOS version | |
| Dock + display (model, resolution, refresh) | |
| Controllers (models, connection) | |
| Baseline (Phase A) Minecraft / Fabric version | |
| Branch (Phase C) Minecraft / Fabric version | |
| Version confound? (versions differ) | yes / no — notes: |
| MangoHud probe verdict — Phase A | PASS / FAIL |
| MangoHud probe verdict — Phase C | PASS / FAIL |
| FPS source used for comparison | MangoHud p50 / human F3 |

## Baseline manifest summary (Phase A step 0)

- Mods present (instance 1): 
- GC flags in baseline `JvmArgs`? (expected no): 
- Notes / deviations between instances: 

## Branch manifest verification (Phase B step 8)

- [ ] 6 perf mods present in every instance's `mods/`
- [ ] `JvmArgs` contains `-XX:+UseG1GC` (Aikar set)
- Notes: 

---

## Per-cycle results

<!-- Duplicate this block for each of: phaseA/1p 2p 3p 4p, phaseC/1p 2p 3p 4p -->

### <phase>/<N>p — <date time>

**summarize.sh segment lines** (paste verbatim):

```
```

**MangoHud** (file / fps_p50 / fps_1pct_low per slot, if available):

```
```

**Human observations:**

| Question | Answer |
|---|---|
| F3 FPS per screen, standing (S1) | |
| Worst F3 FPS per screen, flight (S2) | |
| Smoothness 1–5 | |
| Stutters (none/occasional/frequent + where) | |
| Audio crackle / input lag | |
| Other anomalies | |

**Hygiene checks:** teardown clean (pgrep empty): ☐ · oom-kill in dmesg/journal: ☐ none ·
`SLOT_DIED` in session log: ☐ none · cycle retried? ☐ no

---

## Phase D — Comparison

<!-- One table per N from: summarize.sh phaseA/<N>p --compare phaseC/<N>p -->

### 1P delta table

### 2P delta table

### 3P delta table

### 4P delta table

## Gates

**Hard gates (Phase C):**

| Gate | Threshold | Observed | Pass |
|---|---|---|---|
| 4P completes, no OOM, no SLOT_DIED | — | | ☐ |
| 4P rss_sum_max_mb | ≤ 12288 | | ☐ |
| memavail_min_mb (4P) | ≥ 1024 | | ☐ |
| swap_delta_mb (any cycle) | < 256 | | ☐ |
| psi_mem_full_max (any cycle) | < 5 | | ☐ |
| FPS vs Phase A (per slot/segment/N) | ≥ A − 5% | | ☐ |
| No new failure class | — | | ☐ |

**Soft gates:**

| Gate | Observed | Pass |
|---|---|---|
| Smoothness ≥ baseline at each N | | ☐ |
| Stutter not worse | | ☐ |
| apu_temp_max_c not sustained >95 | | ☐ |

## Verdict

- **Decision:** merge / no merge / maintainer call
- **Rationale:**
- **Follow-ups / issues opened:**
