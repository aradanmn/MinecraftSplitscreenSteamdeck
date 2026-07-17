# Research: 4 Concurrent Minecraft Instances on Steam Deck (16GB) — 2026-07-17

User-supplied research doc, adopted as the basis for the standard install mod
set and per-instance JVM flags. Implementation status annotations added where
this repo deviates; original content otherwise preserved.

## Goal
Run up to 4 simultaneous Minecraft Java sessions on Steam Deck with improved
visuals, without CPU/GPU contention crashing performance, and without exceeding
available RAM.

## Loader
Use **Fabric** (lighter than Forge/NeoForge, best support for perf mods below).
*[Already this repo's loader.]*

## Required Mods (install identically in all 4 instances)
| Mod | Purpose | Status |
|---|---|---|
| Sodium | Rendering engine rewrite — primary FPS gain | ✅ required in mods.conf |
| Lithium | General game-logic optimization, no memory cost | ✅ required in mods.conf |
| Starlight | Rewrites lighting engine, removes CPU spikes from chunk lighting | ❌ **dropped** — Fabric port archived, capped at MC 1.20.4; would never resolve against the recent versions this installer targets (user-confirmed 2026-07-17) |
| FerriteCore | Reduces per-instance memory footprint — critical at 4x concurrency | ✅ required in mods.conf |
| ModernFix | Faster startup + extra memory/CPU optimizations | ✅ required via the **ModernFix-mVUS** fork (`TjSm1wrD`) — the original stopped cutting Fabric builds for current MC versions |
| Entity Culling | Skips rendering off-screen entities | ✅ required in mods.conf |
| ImmediatelyFast | Optimizes immediate-mode rendering calls | ✅ required in mods.conf |

## Avoid / Use With Caution
- **C2ME** — multithreaded chunk generation competes hard for CPU cores across
  4 instances; skip unless each instance has dedicated cores.
- **Iris / shader packs** — visually nice but expensive across 4 sessions;
  limit to one instance if used at all.

## Memory Budget (16GB total)
- Reserve ~3–4GB for SteamOS + background processes
- Remaining ~12GB split across 4 instances = **~3GB max per instance**
- Set `-Xmx3G` (and `-Xms2G` to avoid over-reserving at launch) per instance

*[Status: `-Xmx` matches — `instance_creation.sh` already sets
`MCSS_MAX_MEM_MB=3072` per instance via PolyMC's `MaxMemAlloc`. `-Xms` kept at
the repo's existing 512M (`MCSS_MIN_MEM_MB`) rather than the doc's 2G: with
`-XX:+AlwaysPreTouch` below, `Xms2G` would commit 8GB across 4 instances at
launch before any of them needs it.]*

## JVM Launch Flags (Aikar's flags, tuned for 3GB heap)
```
-Xms2G -Xmx3G
-XX:+UseG1GC
-XX:+ParallelRefProcEnabled
-XX:MaxGCPauseMillis=200
-XX:+UnlockExperimentalVMOptions
-XX:+DisableExplicitGC
-XX:+AlwaysPreTouch
-XX:G1NewSizePercent=30
-XX:G1MaxNewSizePercent=40
-XX:G1HeapRegionSize=8M
-XX:G1ReservePercent=20
-XX:G1HeapWastePercent=5
-XX:G1MixedGCCountTarget=4
-XX:InitiatingHeapOccupancyPercent=15
-XX:G1MixedGCLiveThresholdPercent=90
-XX:G1RSetUpdatingPauseTimePercent=5
-XX:SurvivorRatio=32
-XX:+PerfDisableSharedMem
-XX:MaxTenuringThreshold=1
```

*[Status: adopted as `MCSS_JVM_GC_FLAGS` in `instance_creation.sh`, written to
every instance.cfg as `JvmArgs` with `OverrideJavaArgs=true` — minus the
`-Xms/-Xmx` line, which PolyMC injects from `Min/MaxMemAlloc` (duplicating it
in JvmArgs would put the option on the java command line twice).]*

## Notes for Implementation
- Apply the same mod list + JVM flags to each of the 4 instance
  directories/profiles. *[Done — installer loop writes all instances
  identically.]*
- Confirm total resident memory usage across all 4 instances stays under ~12GB
  during actual play testing; adjust `-Xmx` down if OS starts swapping.
  *[Pending Deck validation, per SPEC §3a/§3b.]*
- If using a launcher that manages multiple instances (e.g., Prism Launcher,
  MultiMC), set these flags per-instance in its Java settings, not globally.
  *[Done — per-instance instance.cfg, not a global PolyMC setting.]*
