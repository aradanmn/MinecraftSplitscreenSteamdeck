# MEMORY.md — Running Change History

A chronological log of significant changes to this project: **what** changed,
**why**, and the **decision** behind it. Newest entries at the top. Pairs with the
per-day `SESSION-*.md` (full narrative) and `DECISION-LOG-*.md` (decision detail)
files.

---

## 2026-07-20 — #70: cap maxFps to live display refresh (launch-time, dynamic)

**What:** Minecraft's `maxFps` is no longer the hard-coded `120` from the installer
heredoc — at play time each instance's `options.txt` is rewritten to the host
display's **current refresh** on every launch. New `mcss_detect_max_refresh()`
(runtime_context.sh) returns the MAX current-mode refresh across enabled outputs;
`mcss_query_displays` gained a 4th output field (refresh Hz) parsed from all three
tools (kscreen-doctor `@RR*`, wlr-randr `NN Hz (current)`, xrandr `NN.NN*` — the
xrandr awk now buffers connector records because the rate sits on the mode line, not
the connector line). Its two existing `read` callers (mcss_resolve_screen,
dock_detection) took a throwaway 4th var. `_start_nested_plasma` samples refresh in
the **host** context (before nesting), exports `MCSS_MAX_REFRESH_HZ`, and the value
rides `mcss_exec_env_string` to the nested `spawn_instance`, which does the per-slot
`sed`/append on `^maxFps:`. On by default (`MCSS_CAP_FPS_TO_REFRESH=1`); fallback 60,
clamp [30,360]; `MCSS_MAX_REFRESH_HZ` doubles as an explicit override. New env vars
are constants in the runtime_context guarded block; installer heredoc keeps
`maxFps:120` as a labeled pre-launch placeholder (installer can't source
runtime_context.sh). Tests T23–T26 added (28/28), CI baseline 22→28.

**Why:** Issue #70's live owner direction (2026-07-18, superseding the earlier
close-as-moot): BENCH-AB measured 300–600 fps per screen into a 60 Hz panel at
92–94% CPU (4P). Frames above the panel's scanout are discarded; capping `maxFps` to
refresh converts them into thermal/CPU headroom and better 1%-lows. Maintainer chose
launch-time (dynamic to whatever display is actually connected), current-active
refresh, on by default.

**Decision / gotchas:** Sample in the HOST context ONLY — the nested XWayland reports
a **synthetic 60 Hz**, so the nested code trusts the inherited value and never
re-probes (the override-wins branch enforces this). `wlr-randr` stays forbidden at
play time (gamescope kills throwaway Wayland clients); the probe list is X11-only
(kscreen-doctor KDE-gated, then xrandr). Steam's per-game Framerate Limit / Refresh
Rate needs no special case — sampling the host output mode picks up whatever SteamOS
scans out (incl. a user-set 30 Hz), and Steam's fps limiter composes on top. **Open:**
whether the outer Game-Mode gamescope probe returns a true refresh (not KDE, so only
xrandr runs against gamescope's XWayland) needs an on-Deck check; degrades safely to
the 60 fallback / override otherwise. Per-slot-count render-cap variation
(renderDistance/heaps, the other half of #70's original scope) remains out of scope.

## 2026-07-17 — Architecture audit + placement law (docs + issues, no code)

**What:** Three-agent audit of all 27 scripts (~12k lines): full interaction map
(installer chain, runtime FIFO architecture, standalone tools), magic-number sweep,
duplication sweep. Produced `docs/AUDIT-ARCHITECTURE-2026-07-17.md` (mermaid block
diagrams + findings) and `docs/ARCHITECTURE.md` (the placement law: domain
ownership per module, globals decision ladder, sourcing rules, duplication budget
for standalone scripts). Filed #85–#91; deliberately did NOT duplicate #47 (token
×7) or #27.

**Why:** Maintainer question: duplication was "supposed to be stamped out already"
by the D1–D17 kill-list — why is it back? Audit's answer: it never fully left. The
consolidations built the right homes (runtime_context, fetch_url, the manifest,
mcss_query_displays), but (a) specific sites were never migrated (flock -w 5,
_reflow_layout's private probe, launcher_setup's fallback-less mem reads), (b) the
data was consolidated without the code (one manifest, four parsers), and (c) there
was no written rule telling new code where functions/globals GO — STYLE-GUIDE.md
covers naming/format only.

**Decision:** Yes to an architecture document (maintainer asked). ARCHITECTURE.md
is the living law, the audit doc is the point-in-time record. Key rules: MCSS_*
only in a constants root; "a constant's existence obligates its use" (naming a
value + leaving the literal elsewhere is worse than no constant); consumer-side
`:-fallback` re-embedding of literals is the drift pattern to reject; standalone
scripts may duplicate only with a `# PAIRED WITH` comment. Fix ordering in audit
§7: mechanical (#86) → correctness-adjacent (#85/#87) → mod-pipeline dedup
(#47+#88) → prototype-path deletion (#90) → structural merges (#89/#91), merges
BEFORE the #52 retrofit.

**Status:** docs + TODO/MEMORY on `claude/script-diagram-refactor-9f3qw6`; issues
live. Same-day follow-up: #85/#86/#87/#47/#88/#90 implemented on this branch in
six commits (implementer/verifier split: Sonnet wrote, Fable adversarially
verified before every push — the verify pass caught 17 malformed API URLs from
in-string line continuations before they ever hit origin). All [CODE], NOT
Deck-validated; #89/#91 (structural merges) deliberately not started — they
reshape the installer module layout and deserve their own pass after this
batch validates on hardware.

## 2026-07-17 — A/B benchmark harness for the mod-set/JVM-flags change

**What:** New `tests/benchmark/` tooling to Deck-validate the standard-mod-set +
JVM-flags change with numbers instead of vibes: `sampler.sh` (background /proc+sysfs
metrics sampler — CPU, RAM, swap, PSI, GPU busy/VRAM, APU temp, per-slot java
CPU/RSS/IO via the state file), `summarize.sh` (per-segment stats + A/B delta
tables), `mangohud-wrapper.sh`/`mangohud-ctl.sh` (probe-gated objective FPS via
PolyMC WrapperCommand, fail-open to F3-only), `RUNBOOK.md` (the full protocol:
baseline 1P→4P on the existing install → checklist-gated full torch → fresh install
from the branch → identical re-run → hard/soft merge gates), `RESULTS-TEMPLATE.md`.

**Why:** The 2026-07-17 mod/flags entries below are NOT Deck-validated; maintainer
wants a measured before/after (and the SPEC §3a D6 "no OOM at 4P / RAM budget" check
formally closed) before merging to main.

**Decision:** Zero module changes — MangoHud rides `OverrideCommands=true` +
`WrapperCommand` in instance.cfg (survives spawn's JvmArgs rewrite; logs must live
under $HOME because each slot's /tmp is a private tmpfs). Execution model: a driver
Claude session on the Deck runs the runbook, the human plays; sampler CSVs stay on
the Deck, summary tables get committed as `docs/BENCH-AB-<date>.md`.

**Status:** tooling smoke-tested off-Deck (synthetic CSV math verified); benchmark
itself not yet run.

---

## 2026-07-17 — Standard performance mod set (all [CODE], NOT Deck-validated)

**What:** Replaced `mods.conf`'s optional Sodium-extras/QoL mods (Sodium Options
API, Reese's Sodium Options, Sodium Extra, Sodium Extras, Sodium Dynamic Lights,
Better Name Visibility, Full Brightness Toggle, In-Game Account Switcher, Just
Zoom, Mod Menu, Old Combat Mod) with a required performance baseline: Sodium,
Lithium, FerriteCore, ModernFix (via the `ModernFix-mVUS` fork, project
`TjSm1wrD` — the original `nmDcB62a` stopped cutting Fabric builds for current
MC versions), Entity Culling, and ImmediatelyFast. mods.conf now has no
`optional` entries left. Also fixed `get_supported_minecraft_versions()`
(`version_management.sh`) to gate on *every* required mod's compatibility
instead of a hardcoded Controlify-only check, since that check now decides
whether 6 more required mods will actually resolve for the offered MC version.

**Why:** User-provided research doc on running 4 concurrent Minecraft sessions
on a 16GB Deck; wanted its recommended perf mod set adopted as the default and
the unrelated optional QoL mods dropped.

**What (2):** Adopted the doc's Aikar-style JVM GC flags as
`MCSS_JVM_GC_FLAGS` (`instance_creation.sh`) — written into every instance.cfg
as `JvmArgs` with `OverrideJavaArgs=true`, minus `-Xms/-Xmx` which PolyMC
injects from `Min/MaxMemAlloc`. Doing so exposed two runtime bugs in
`instance_lifecycle.sh` §2.5: (a) `setInstanceCfgValue` was a "preserved
function" of the pre-modular launcher that never made it into any module, so
spawn_instance's calls to it died with exit 127 under `set -e` — defined it;
(b) the spawn-time JvmArgs write clobbered the whole value with just the
window-title property — factored `_set_jvm_window_title` which merges the title
into the existing flags (and strips stale title tokens on re-spawn). Tests:
T4.13, plus T7.9 regression on the mods.conf decisions. Research doc archived
at `docs/RESEARCH-4X-INSTANCE-PERF-2026-07-17.md`.

**Decision:** Left Starlight out — its Fabric port is archived, capped at MC
1.20.4, and would never resolve against the recent versions this installer
targets; confirmed with the user before dropping it. The existing per-instance
JVM heap sizing (`instance_creation.sh`: `MCSS_MAX_MEM_MB=3072`, 4×3G ≈ 12GiB
on 16GB) already matches the doc's memory-budget guidance, so left untouched;
kept `MCSS_MIN_MEM_MB=512` over the doc's `-Xms2G` because `-XX:+AlwaysPreTouch`
would commit 4×2G = 8GiB at launch.

**Status:** pushed to `claude/standard-install-mods-yfox41`, awaiting Deck
validation per this project's standing rule (SPEC §3a/§3b).

---

## 2026-07-01 — Codebase review + v1.1 fix batch (all [CODE], NOT Deck-validated)

**What:** A full codebase + open-issue review, followed by a fix pass in the same
session: the #43 architectural root-cause (no authoritative environment/mode global,
closes #42's Desktop-Mode runaway at the source instead of just its symptom), the #40
`_set_mode` crash, #15's nested-session teardown (stopped `exec`-ing away the outside
supervisor so a bounded reap loop can out-wait systemd's respawn), and 14 smaller
audit-tracked issues (#16-27, #31, #32) spanning monitor heartbeats, reflow retry,
the controller_monitor snapshot-skew race, KWin PID-only matching, and several
smaller hygiene/robustness fixes. Added the project's first CI (shellcheck +
baseline-gated unit tests) and a research doc on how Steam/SDL/InputPlumber actually
handle controller-reconnect identity (feeds #38).

**Why:** The issue tracker had 23 open items and no CI; several (#42/#40 in
particular) were live, user-visible bugs on the current `main`. #43 was flagged in
its own issue as "the architectural root behind a recurring 'nothing told the code
what context it's in' failure mode" — worth fixing before patching more symptoms.

**Decision:** Fixed forward rather than redesigning — e.g. #15's fix keeps the
existing `_end_nested_session` kill-by-name approach but wraps it in a supervising
outer loop, rather than a rewrite. Full list + issue cross-references in TODO.md's
2026-07-01 entry. Left the RAW-CONTROLLER-BIND-PLAN.md rewrite untouched (still
flag-gated, still needs the in-sandbox SDL probe it names before flipping default) —
the research doc informs it but doesn't implement it.

**Status:** pushed to `claude/codebase-review-v1-1-120ktb`; awaiting Deck validation
per this project's standing rule (SPEC §3a/§3b) before anything here is "done."

---

## 2026-06-19 — Docs decluttering pass

**What:** Reduced root-level `.md` clutter (was 15 files, ~400KB).
- **Deleted** (recoverable from git history): `HANDOFF.md` (pre-windowing handoff for
  the abandoned `claude/elegant-bell-vdupw5` branch) and `IMPLEMENTATION_HANDOFF.md`
  (63KB spec for the launcher rewrite that is now implemented in `modules/`).
- **Archived to `docs/archive/`**: `WINDOWING-SPEC.md`, `PLAN-WINDOWING-CONTROLLERS.md`,
  `RESEARCH-GAMESCOPE-WINDOWING.md`, `windowing-analysis.md` — superseded windowing
  planning/research, kept for the reasoning trail with an explanatory
  `docs/archive/README.md`.

**Why:** The two deleted handoffs described complete or dead work and had zero
inbound references. The four archived docs were overlapping 2026-06-17 "challenge &
refine" explorations of the windowing problem that `SESSION-2026-06-17B.md` later
solved with a *different* approach (nested KWin via autostart, not the `dex` /
nested-Xwayland path some of these recommended) — superseded for current work but
valuable as decision history.

**Decision:** Archive rather than delete the planning cluster (browsable folder beats
git-archaeology for the "why"); delete only the two truly dead handoffs. README
references none of these, so no user-facing links broke. Updated the two internal
references to `PLAN-WINDOWING-CONTROLLERS.md` (in DECISION-LOG-2026-06-17.md and
GAMESCOPE-WINDOWING.md) to the new archive path. Left `SESSION-2026-06-16.md` (226KB
raw log) in place as history.

**Kept as authoritative:** README, MEMORY, GAMESCOPE-WINDOWING, and the
2026-06-17/2026-06-19 SESSION + DECISION-LOG files.

---

## 2026-06-19 — bwrap GPU regression fixed

**What:** In both `launchSlot` functions (`minecraftSplitscreen.sh` ~L171 and
`modules/launcher_script_generator.sh` ~L338), re-bound the GPU and supporting
paths into the bwrap sandbox after `--dev /dev`:
`/dev/dri`, `/dev/fuse`, `/dev/shm`, `/tmp/.X11-unix` (each existence-guarded).

**Why:** `--dev /dev` mounts a fresh empty devtmpfs over `/dev`, wiping the
`/dev/dri/*` GPU nodes that `--dev-bind / /` had provided. Qt's xcb platform
plugin (and LWJGL) need the GPU to initialize, so PolyMC was exiting silently.

**Decision / context:** A handoff prompt recommended **removing bwrap entirely**,
claiming a separate unfixable SingleApplication/abstract-socket bug. git history
proved otherwise: working commit `d5f060c` did `--dev /dev` **and re-bound
`/dev/dri` afterward**; Phase A (`38c4f99`) rebuilt `launchSlot` and dropped that
re-bind. The user's memory ("bwrap worked before the window-positioning test") was
correct. We fixed the regression instead of removing the sandbox.
- Controller isolation = `--bind /dev/null <other-pads>`, NOT `--unshare-net`.
- SingleApplication forwarding is the *intended* way one PolyMC primary launches
  all 4 JVMs — it only appeared broken because the GPU bug killed the primary.
- The per-slot `XDG_RUNTIME_DIR=/tmp/polymc-runtime-slotN` hack is a no-op for
  abstract sockets; left in place as harmless.
- Process note: delegation default is `llama3.1:8b` which cannot reliably call
  tools (fabricated a fake success here). Repoint delegation at `qwen2.5-coder:14b`.

**Commit:** `d348bf1` on `feat/gamescope-windowing`.
**Status:** pushed; awaiting Deck test (expect 4 windows in 2×2 grid).
**Refs:** SESSION-2026-06-19.md, DECISION-LOG-2026-06-19.md

---

## 2026-06-17 — Windowing solved via nested KWin; controller isolation plan

**What:** Established nested-KWin-inside-gamescope approach for window positioning;
documented SDL env configuration for controller isolation.

**Why / decisions (summary — see DECISION-LOG-2026-06-17.md for full detail):**
- xdotool geometry tested directly in gamescope first (no Xephyr dependency).
- gamescope ignores `ConfigureRequest`, so a nested WM (KWin) is required to
  actually reposition OS windows; the Splitscreen mod only controls the viewport.
- Controller isolation: `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1`,
  clear `SDL_GAMECONTROLLER_IGNORE_DEVICES`, `SDL_JOYSTICK_HIDAPI=0`; mask the
  Deck built-in `28de:11ff` event node with `--bind /dev/null` per sandbox.

**Refs:** SESSION-2026-06-16.md, SESSION-2026-06-17.md, SESSION-2026-06-17B.md,
DECISION-LOG-2026-06-17.md
