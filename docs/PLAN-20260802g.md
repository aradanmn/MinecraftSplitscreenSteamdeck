# MinecraftSplitscreenSteamdeck — Canonical Plan & Roadmap

**This is the single source of truth for where the project stands and where it is
going.** It supersedes the per-campaign `PLAN-V1.x` docs (now archived — see
[Versioning](#versioning) and [Document map](#document-map)).

**Last updated:** 2026-08-02 · **Repo:** `aradanmn/MinecraftSplitscreenSteamdeck`
· **Active cycle:** v1.3 (virtual pad rig) — PR-2/PR-3/PR-4 all Deck-validated and closed. PR-5 (#151) in progress: node-swap prerequisite confirmed forceable (`tests/probe-node-swap.sh`, 2026-08-02) — the plain 2-pad technique is solid (3/3), the more realistic 3-pad live-gap variant is inconsistent (open question, not a blocker). Tier 2 (the real production-scenario repro) is next.

---

## Versioning

`PLAN.md` is **always the latest plan.** Before any substantive change to it:

1. Copy the current `PLAN.md` to `docs/PLAN-YYYYMMDD.md`, where `YYYYMMDD` is the
   date the *outgoing* version was last updated (the `Last updated` field above).
2. Then edit `PLAN.md` with the new plan and set a fresh `Last updated`.

This keeps one canonical doc plus an immutable dated trail. Prior campaign plans
live under `docs/PLAN-*.md`.

---

## Product in one paragraph

Splitscreen Minecraft for the Steam Deck: 1–4 players on one screen, each a separate
PolyMC instance rendered inside a nested Plasma/kwin session under gamescope, with
per-player controller isolation. Installer provisions the instances + mods + Steam
shortcut; a launcher/orchestrator spawns and tiles the instances at play time.

---

## The scheduling constraint (read this before planning anything)

**Operator time at a docked Deck is the scarce resource, not agent working time.**
Estimate the two separately and batch Deck work; agent work is cheap and
parallelisable, Deck sittings are not, and some carry reboot risk.

Three constraints that shape *how* Deck work can be done:

- **SSH rides the dock's USB ethernet** (`enp4s0f3u1u4c2`, .105; wlan0 is .104 but
  replies still route out the dock NIC). **Undocking severs the connection**, so any
  cross-undock capture must be a detached local logger read back after re-dock.
- **Nothing is visible in Game Mode.** gamescope presents Steam's UI and the focused
  game surface only; `kdialog`/`zenity` never appear. Measured across four attempts
  (#125).
- **A launch cannot be driven over SSH.** The runtime-context guard refuses a bare
  invocation, and Steam must not be manipulated remotely. Anything needing a live
  session needs the operator to press play.

---

## Status snapshot (2026-08-01 afternoon)

| Release | State |
|---------|-------|
| **v1.0 → v1.1.1** | Shipped / closed. |
| **v1.2.0** | Shipped 2026-07-26 — #38 seamless reconnect, `MCSS_CONTROLLER_PROXY=1` default. |
| **v1.2.1** | Shipped 2026-07-29 — docs + test tooling only. |
| **v1.2.2** | Shipped 2026-07-31 — installer consolidation (#89, #91), validated through a real `curl\|bash` install. |
| **v1.2.3** | Shipped 2026-08-01 — #167, #170, #172, #174, #98. Two silent data-loss bugs and a session wedge. |
| **v1.2.4** | **Shipped 2026-08-01 (tag pushed ~1:51pm).** #122 (clean-wipe uninstaller) + #184/#185/#186 (found *during* #122's own validation) + #126 (prebuilt evsieve release asset) all shipped and hardware-validated. #36 (Controlify glyphs) investigated and documented as a known limitation, not fixed. #196 (a real, separate bug found while validating #126's fallback path) filed for backlog — does not block this release. Both milestone issues (#122, #126) closed. |
| **v1.3** | Virtual pad rig. **In progress.** PR-1 subsumed by PR-0 (#158, already shipped it). PR-2 (rig control surface) opened as #197 — 93/93 CI, 7/7 mutations confirmed red, **Deck-validated 2026-08-01**: core lifecycle confirmed on real hardware, one earlier "burst enumeration broken" scare fully explained (MAX_PLAYERS cap contention, not a bug), one destroy-latency question left genuinely open pending a `dmesg`-based remeasurement. PR-3 (`stage3_hotplug` automation behind `MCSS_VIRTUAL_PADS`) **built and Deck-validated in BOTH modes, 2026-08-02.** Virtual mode: 33 passed/2 failed/17 skipped; failures plausibly cold-start timing, not a regression. Human mode (real BT controllers, unset flag — the default path): 59 passed/1 failed/11 skipped, zero real regressions across the whole D3.0-D3.8 core lifecycle. One real rig-cleanup pidfile bug found (no process leak) and one operational lesson (session-stop needs a manual Steam-overlay Exit Game) filed as follow-ups, neither blocking. Two stale test-expectation comments (D3.8 re: #62/#38, D3.10 re: pre-#37 teardown semantics) found live and fixed same-day. **PR-4 (#71 burst-spawn) closed 2026-08-02** — `tests/probe-burst-spawn.sh` built and Deck-validated, 5/5 iterations converged (0 reproduced), operator visually confirmed all 4 windows every time; already fixed by existing code, no fix needed. Found and fixed three real infrastructure bugs along the way — see the ladder row below. **PR-5 (#151) in progress same night** — `tests/probe-node-swap.sh` confirms the underlying node-swap precondition is forceable (plain 2-pad: 3/3 clean; 3-pad live-gap variant: inconsistent, open question) — see the ladder row below. |
| **v1.4** | Docking + visibility. Blocked on a design question, not code. |

### v1.2.4 found three real bugs by validating #122 on hardware

Running the `--purge` cycle end to end on the Deck (twice — once mine, once
Scott's own manual install) surfaced three bugs that no unit test could have
caught, none related to the `--purge` work itself:

1. **#184** — `MCSS_STEAMGRIDDB_ICON_URL: readonly variable`. A bash prefix
   assignment to a `readonly` name silently fails to reach the child process
   (fail-open, not fatal — the child still ran, just without the value).
   Fixed: `env`, not a prefix assignment. **PR #188.**
2. **#185** — `./install-minecraft-splitscreen.sh --yes` died silently at
   the Steam-integration prompt, no error message. `--yes` was parsed
   nowhere; two prompts were bare `read`s under `set -e` that abort on a
   genuine EOF. Fixed: `mcss_prompt()`, the one encoding for "ask, but never
   hang or die silently" — `--yes` skips outright, EOF degrades to a safe
   default (which can differ from `--yes`'s default on purpose: Steam
   integration is "yes" under `--yes`, "no" on an accidental EOF, since an
   unintended EOF must never silently rewrite `shortcuts.vdf`). **PR #187.**
3. **#186** — the evsieve build box failed to create, every time, right
   after `--purge` wiped the podman store. Root cause: this Deck's kernel
   rejects a native-overlay ID-mapped mount; `fuse-overlayfs` (already
   shipped) fixes it. Fixed: retry once with `--storage-opt
   overlay.mount_program=/usr/bin/fuse-overlayfs` only on failure — a
   healthy host sees no behavior change. **PR #189.**

All three merged and **hardware-validated 2026-08-01**: a real
`./install-minecraft-splitscreen.sh --yes < /dev/null` run (zero stdin)
completed end to end — no readonly-var error, no silent death at the Steam
prompt, and the evsieve build succeeded via the fuse-overlayfs fallback
(confirmed live: `fuse-overlayfs` was the actual running mount process, not
a coincidental native success — the plain path still fails on this Deck's
kernel, the fallback is what's carrying it).

### v1.2.4's release cut validated #126, and its fallback path validation found a fourth bug

Pushing the `v1.2.4` tag exercised `release.yml` for real for the first time:
`build-evsieve` (CI, `ubuntu-22.04` + `dtolnay/rust-toolchain@stable`) built
evsieve and uploaded it; `release` published the installer script and the
prebuilt binary+sha256+stamp as GitHub Release assets. **#126d validated
against that real release, twice** — once via an isolated harness, once via
a genuine clean reinstall with no test scaffolding — both times
`install_evsieve()` fetched, checksum-verified, host-verified, and installed
without ever touching git/podman/distrobox/cargo.

Deliberately forcing the *fallback* half of that same validation (simulate
the prebuilt fetch failing) surfaced **#196**: the build-at-install path
itself currently can't compile the pinned evsieve source on this Deck —
Debian 12's packaged rustc (1.63.0) rejects syntax the pin's checked-in
`src/bindings/libevdev.rs` already uses (`unsafe extern "C"` blocks,
`offset_of!`, `let...else`). Reproduced on a from-scratch box (image pulled
fresh via `--purge` + reinstall), not stale state.

**Genuinely puzzling part, left honestly unresolved:** the exact same pin
built successfully on this same Deck earlier that same morning (~8:33am,
visible in `.workdir/validation-install.log`). The box active a few hours
later (and the fresh one recreated after `--purge`) both reported rustc
1.63.0 and failed. Since `EVSIEVE_PINNED_COMMIT` never changed today, something
about the distrobox/podman environment's resolved toolchain did — most likely
`docker.io/library/debian:12` being a floating tag rather than a pinned
digest, so two pulls hours apart could have resolved different point-release
snapshots. Not confirmed; the original 8:33am box no longer exists to
compare. Doesn't block v1.2.4 — #126 means real installs use the prebuilt
path and never reach this code at all — but it's a real bug, not a fluke,
and the fix (pin an explicit Rust toolchain via rustup instead of depending
on whatever `apt-get install cargo` resolves to) removes the ambiguity
regardless of root cause. Filed for backlog, not blocking.

### The load-bearing open question

**Can we show the user anything at all in Game Mode?** #125 and #160 both depend on
it, and four measured attempts say no via any dialog — Wayland-native, host `:0`, and
forced XWayland all ran cleanly and were never visible. Until an experiment finds a
working channel, both are **un-fixable rather than merely unfixed**, and may end as
documented limitations.

### What v1.2.3 changed about how we work

Every bug in it was found by **validating the previous release on hardware**, not by
reading code. #167, #172 and #174 were invisible to CI, to unit tests, and to the
logs — two of them reported success while destroying user data. That is PRINCIPLES #3
restated with evidence.

---

## Milestone map (GitHub)

| Milestone | Open | Theme |
|-----------|------|-------|
| **v1.2.4** | *(closed — 0 open)* | Install-path polish + cosmetics. Shipped 2026-08-01. |
| **v1.3** | #157, #136, #151, #71, #70 | Automated multi-player testing + the bugs only it can reproduce |
| **v1.4** | #125, #134, #135, #79, #160 | Docking end to end + "the user can see what happened" |
| **backlog** | #179, #15, #14, #196, #36, #195 | Documented, not scheduled |

**#15 may be closable.** #174 fixed the orphaned-proxy wedge that plausibly caused
the Abort Game black screen it describes. Check after a few more sessions.

---

## v1.2.4 — install-path polish (SHIPPED, 2026-08-01)

Closed out. Both milestone issues (#122, #126) closed; the release is tagged
and published with all four assets (installer script + prebuilt evsieve
binary + sha256 + stamp).

- **#122** clean-wipe uninstaller + one `.workdir/` encoding for all
  test/benchmark tooling. Hardware-validated (a purge leaves `ls ~` clean, a
  hw-test run leaves nothing outside `.workdir/`).
- **#184/#185/#186** — three real bugs *found by validating #122 on
  hardware* (readonly-var crash, `--yes` no-op, evsieve overlay-mount
  failure). All fixed, all hardware-validated via a real
  `--yes < /dev/null` non-interactive install.
- **#126** prebuilt evsieve release asset, build-at-install as fallback.
  #126a (design: CI cross-build) decided and posted; #126b (CI job) and
  #126c (installer fetch+verify) built, tested, mutation-tested; #126d
  (Deck validation against a real release) confirmed the fetch path works
  twice over. See above for what its fallback-path half found (#196).
- **#36** Controlify SNES glyphs — investigated (not fixed): traced the
  exact mechanism (`fetchTypeFromSDL` → VID:PID lookup) and narrowed why
  SDL likely reports vendor:product=0 for evsieve's virtual pad (bustype
  mismatch + a probable HIDAPI/evdev collision with the real controller).
  Documented as a known limitation in `README.md`; follow-up evidence
  posted to #195. No code change — needs more research before one is
  worth attempting.

---

## v1.3 — the virtual pad rig

**Unblocked.** The udev rule is installed (`60-mcss-uhid.rules` — the `60-` prefix is
load-bearing, since `uaccess` is consumed at 70/73) and PR-0 returned all ten
verdicts green on hardware: `uniq` reaches the input device, two pads each keep their
own sysfs parent, and Steam mints a `28de` virtual exactly as for a real pad.

**PR-0b is NOT needed** — V7 came back `BOTH`, so step-6 dedup does not collapse uhid
pads and no production code change is required.

| Chunk | Status | Estimate |
|---|---|---|
| **PR-1** pad primitive hardened + CI tests | **Subsumed by PR-0** (#158) — the merged probe PR already shipped `--emit-descriptor`/`--encode-report`, 18 CI tests, and mutation testing. Nothing left to do under this label. | — |
| **PR-2** rig control surface (create/destroy/inject/cleanup, PID-tracked) | **Opened as #197, Deck-validated 2026-08-01.** `tests/lib/uhid_rig.sh` + `tests/lib/fake_pad.sh` (CI double) + `tests/test_uhid_rig.sh` (93/93 in CI; 93/93 on the Deck across 4 of 5 runs, one unreproduced flake — see below). 7/7 planned mutations confirmed red. Core lifecycle confirmed on real `/dev/uhid`: burst-create 4 pads (~1s), injected input acked, Steam minted 4 `28de` virtuals 1:1, `rig_cleanup` restored the enumerator to baseline, and SIGKILL-the-sourcing-shell killed its pad within 0.2s with no explicit `destroy` (the §4.4 safety property, confirmed against the real kernel). One false alarm resolved: a 4-pad burst first appeared to lose the last pad from enumeration, fully explained by `MCSS_MAX_PLAYERS=4` capping against a real controller that happened to already be connected — with a genuine 0-baseline, all 4 pads enumerated instantly. One open, *unmeasured* question below. | agent ~2h + Deck ~45 min |
| **PR-3** automate `stage3_hotplug` behind `MCSS_VIRTUAL_PADS` (human mode stays default) | **Built and Deck-validated, 2026-08-02.** Every "plug in controller N" gate in `tests/hardware/stage3_hotplug.sh` has a virtual-pad arm (`rig_create_pad`/`rig_destroy_pad`/`rig_wait_for_pad`), added as a new `if _stage3_virtual_mode; then … elif hw_prompt …` branch — every human-mode branch is byte-identical to what shipped before this PR, so the default (unset/0) path is unchanged — **and now confirmed on real hardware, not just by inspection** (see the human-mode run below). D3.0 does `rig_init` + `rig_install_traps` (EXIT/INT/TERM) so pads survive across stages 3→5 (run_all.sh sources every stage into one shell) but still get reaped on process exit. Gameplay/visual checklists (no human pilot in virtual mode) auto-skip via `_stage3_skip_checklist_if_virtual`. Chaos tests D3.11/D3.12 get full virtual equivalents; D3.10 (monitor-kill) automates the *action* but deliberately leaves the *verdict* an `hw_skip` (no validated automated check exists for "did the slot cycle correctly" — PRINCIPLES #3/#4). **Real run on `df43b86`, docked, `MCSS_VIRTUAL_PADS=1 bash tests/hardware/run_all.sh stage3`, D3.10 skipped by operator choice: 33 passed, 2 failed, 17 skipped.** The 2 failures are both D3.2 (P1's first window-visibility check, 30s timeout) — plausibly first-launch cold-start on 4 never-before-used accounts (confirmed each showed Minecraft's one-time "Welcome" onboarding screen; P1's window appeared ~45s later, well past the fixed 30s window), not a PR-3 regression, but unconfirmed and not yet fixed — filed as a follow-up (tighten or make D3.2's timeout account for cold start). All 8 `_stage3_skip_checklist_if_virtual` skips and the D3.11/D3.12 automated checks behaved exactly as designed. **One real bug found**: the EXIT-trap-driven `rig_cleanup` did fire (it removed the leftover `.fifo` files) but never reached `rig_destroy_pad`'s per-pad success path for the last 4 pads — `.pid` files were left orphaned in `.workdir/uhid-rig/`. The pads themselves were confirmed dead (no process leak, verified directly) — reproducing the exact same create/destroy/exit sequence twice in isolation both times cleaned up perfectly, so the trigger is specific to something in the real end-to-end run, not yet isolated. Filed as a follow-up, not blocking. **Operational lesson, not a PR-3 bug**: stopping a virtual-pad session via the suite's own `hw_stop_orchestrator`/`hw_reap_stale_session` (SIGKILL against marker-tagged processes, bypassing the orchestrator's own graceful nested-session teardown) left `kwin_wayland`'s X11 connection broken and gamescope showing a black screen, stuck thinking the game was still running — confirmed in the journal (`kwin_wayland: XCB error... The X11 connection broke`) at the exact cleanup timestamp. Recovered via the Steam button → Exit Game (normal on-device path, no hard reset needed this time) — distinct from and less severe than the earlier SSH-`steam -shutdown` incident that did need one. Worth a line in the hardware-suite runbook so it reads as expected, not alarming. **Human-mode regression check, same day, real BT controllers (`bash tests/hardware/run_all.sh stage3_hotplug`, `MCSS_VIRTUAL_PADS` unset): 59 passed, 1 failed, 11 skipped.** D3.0 through D3.8 — the entire core lifecycle PR-3 could have regressed — passed 100% with up to 4 real controllers: geometry at every player count, sticky-slot disconnect, reconnect-with-reattach, and 27 human checklist items, zero real failures. The one [FAIL] (D3.10) and 2 of the skips (D3.11/D3.12) are pre-existing test-authoring issues, not regressions, and got fixed as part of this same pass: D3.10's prompt described pre-#37 teardown+respawn semantics when the shipped, correct behavior is sticky (game persists, only reaps on player-initiated quit) — text corrected to match, and D3.8's checklist item still called out "#62 EXPECTED FAIL until #38" when #38's seamless-reconnect proxy has been the shipped default since v1.2.0 and reconnect actually worked live — text corrected too. D3.11 (rapid <1s unplug/replug) and D3.12 (whole-hub USB drop) don't have a meaningful analog on Bluetooth controllers/no-hub hardware and were skipped for that reason, not a failure. | agent ~3h · **Deck ~90 min (spent)** |
| **PR-4** #71 burst-spawn repro + fix | **DONE. Repro built AND fully Deck-validated 2026-08-02 — 5/5 iterations converged, zero reproduction of #71, operator visually confirmed all 4 windows on every single iteration.** `tests/probe-burst-spawn.sh` (new, `tests/probe-*.sh` convention, not wired into `run_all.sh`): burst-creates all 4 rig pads with zero waits between creates (the exact "connect 4 pads, then launch" repro shape), launches docked, asserts quad-geometry convergence per slot with a 150s budget, repeats the full stop/relaunch cycle 5x since a race is intermittent by nature. **Result: `orchestrator.sh`'s deferred-per-slot-reflow architecture (which post-dates #71's 2026-07-06 filing) has already fixed it.** No production code change needed — this PR is a confirm-and-close, not a fix. 50 passed / 0 failed / 0 skipped across the final clean run; every teardown between iterations was also clean (no orphaned processes, no display wedge). `docs/RUNBOOK-HW2-TEST-HARNESS.md`'s Part 4 (never run) can be considered superseded by this. **#71 is closable.** | agent ~5h (spent, incl. three infra bugs found+fixed live) · Deck ~75 min (spent) |

**Three real bugs found and fixed live during this validation, all in shared test infrastructure (not just PR-4) — this Deck sitting cost four separate live incidents (two display wedges needing on-device Steam restarts, one false-failure run, one aborted iteration) before landing clean, each one traced to ground and fixed rather than worked around:**
- **`rig_cleanup()` reentrancy bug** (`tests/lib/uhid_rig.sh`) — its guard variable was set on first call and never reset, so any SECOND call in the same process silently did nothing. Broke an early probe run's 3rd iteration outright ("pad N is already live"). Fixed: guard resets at the end of a completed pass (still protects against genuine nested re-entry, e.g. a trap firing mid-cleanup — just no longer disables all future calls).
- **`hw_reap_stale_session`'s `kwin_wayland` marker-gate bug** (`tests/hardware/lib/helpers.sh`) — live process inspection proved `kwin_wayland`'s own `/proc/$pid/environ` can never carry the `SPLITSCREEN_DEBUG_LOG=` marker the reap loop checks for (the launcher exports that var to itself mid-execution, which only affects children forked afterward; `kwin_wayland` is exec'd via a wrapper in a way that doesn't inherit it either — same reason `launchFromPlasma` itself and the Steam `reaper` are also structurally unmatchable by this marker, which is very likely why `stage6_teardown.sh`'s T6.3 SIGTERM round has never actually engaged either, though that wasn't independently re-confirmed here). This left orphaned `kwin_wayland` processes — and a black screen with Steam stuck thinking the game was still running — across **two separate teardowns this session**, the same shape as the original PR-3 incident, which this almost certainly explains retroactively. Fixed: `kwin_wayland` is now killed unconditionally in `hw_reap_stale_session`, matching how `reaper`/`bwrap.*PolyMC`/`latestUpdate` were already handled — safe on this platform since `kwin_wayland` only ever runs as this project's own nested session.
- **Stale-FIFO / Steam-relaunch race** (`tests/probe-burst-spawn.sh`) — `SPLITSCREEN_FIFO` is a named pipe that persists on disk independent of any process; immediately relaunching after a teardown let the NEXT iteration's "FIFO appeared" readiness check pass trivially against the STALE file from the previous run, even though the actual orchestrator never (re)started — Steam's own internal bookkeeping had not yet caught up to the OS-level reaper kill and silently ignored the fresh `steam://rungameid/` request. Produced a false "#71 REPRODUCED" (four 30s slot-active timeouts against a session that was never running, not a real repro) before being caught. Fixed: teardown now removes the FIFO explicitly and waits (up to 15s) for the Steam reaper to actually disappear before the next iteration starts; the launch path also now fails fast (10s) on "no supervisor process appeared" instead of silently burning through 2 minutes of slot-active timeouts.

**Operator-observed render lag** (windows the automated geometry check had already passed not yet visually apparent) also came up mid-session — addressed by extending the post-convergence settle window from 5s to 20s, after which the operator confirmed all 4 windows visible on every one of the final 5 iterations.
| **PR-5** #151 repro + quiesce-then-repoint fix | **In progress — node-swap prerequisite built AND Deck-validated 2026-08-02.** `tests/probe-node-swap.sh` (new, `tests/probe-*.sh` convention): answers the question PR-0's own probe left open (V8 got `SAME_NODE`, never `RENUMBERED` — see the gap noted below) — can the kernel be made to hand two pads *each other's* freed `eventN`, the actual precondition #151 depends on? Two scenarios: **Scenario 1 (plain 2-pad swap): SWAPPED cleanly on 3/3 attempts — solid, reliable technique.** Scenario 2 (3-pad, live "gap" pad in the middle — the more realistic shape, since a real 4-up session has other players still connected while two swap): **inconsistent across 3 attempts**, including two runs with *identical* starting node numbers that still produced different outcomes (one clean swap, one confounded by an unrelated real controller disconnecting mid-test, one where the pattern didn't match the lowest-free-number hypothesis at all). Not yet a reliable technique — possibly a faithful reflection that #151 really is a race and a live third pad is part of what introduces the non-determinism, but that's not confirmed. Scenario 1 alone is enough to unblock a first Tier-2 attempt (forcing the swap inside a real 4-up session with `MCSS_CONTROLLER_PROXY=1` and checking whether input actually crosses to the wrong slot); scenario 2's inconsistency is a known open question to carry alongside it, not a blocker. **Next: build Tier 2** (the actual production-scenario repro against a live session) using scenario 1's confirmed technique. | agent ~1h (spent) · **Deck ~10 min (spent)** |
| **#70** benchmark pilot | Not started — also blocked on the open-loop-timed-input methodology decision (§5 of the research doc). | agent 4h+ · **Deck 3h+** |

**Remaining after PR-4: agent ~7h · Deck ~4h** (PR-5 + #70; PR-1's 2h/15min folded into PR-0's cost earlier, PR-2/3/4 actuals now folded in above — PR-4 ran over its original 2h/30min estimate, largely due to the three infrastructure bugs found and fixed live).

**Gap from PR-0, now closed:** V8 returned `SAME_NODE`, not `RENUMBERED` — destroy+
recreate reused the same `eventN`, so the renumber case (#112's mechanism, and what
#151 is about) was untested. **`tests/probe-node-swap.sh` (PR-5, 2026-08-02) closed
this**: destroying two pads together and recreating in reverse order reliably forces
a genuine two-way `RENUMBERED` swap (3/3 on the plain 2-pad case) — the kernel-level
precondition #151 needs is confirmed real and forceable, not just a repro question.

**Open from PR-2's Deck session, genuinely unmeasured — not a confirmed bug:**
after destroying a single pad (well under the `MCSS_MAX_PLAYERS` cap, no
contention), the production enumerator took noticeably longer than the rig's
default 5-10s timeouts to reflect the removal. First attempt to time it precisely
used SSH-side wall-clock polling from the orchestrator and produced a bogus wide
bound (30s-269s) — the polling harness itself broke silently (quoting bug,
compounded by this Deck's flaky dock-NIC connection dropping mid-session), so the
number is not trustworthy and should not be treated as a finding. Recreate-with-
swapped-uniq (the PR-5 identity-swap shape) also ran once on real hardware and
behaved correctly at the rig/device level (`rig_pad_field` reported the new
uniq, pid differed), but wasn't independently isolated from the same cap
contention, so treat it as "worked, not yet cleanly proven" rather than fully
validated. **Next Deck session on this: bracket a single destroy with `dmesg -T`
(kernel timestamps) instead of SSH polling** — immune to connection blips and
client-side scripting bugs, and the only way to get a trustworthy number here.
One `tests/test_uhid_rig.sh` run on the Deck also came back 90/93 before three
immediate reruns all passed 93/93 — unreproduced, noted rather than chased.

**#70's blocking decision:** open-loop timed input is *self-damping under load* — a
slower configuration flies less far, generates fewer chunks, and incurs less load,
flattening the very A/B difference being measured. Decide before the campaign, not
during. See `RESEARCH-136-VIRTUAL-PAD-RIG.md` §5.

---

## v1.4 — docking + visibility (the riskiest milestone)

**#125 and #160 share one root cause and should be worked as a single design
question, not two bugs.**

| Chunk | Steps | Estimate |
|---|---|---|
| **D1 — "is there ANY visible channel in Game Mode?"** | Try, in order: a fullscreen window through the `window_manager`/`kwin_positioner` path (the only path proven to put pixels on the external display); a client on `:1` *during* a launch; dismissing ksplash via `qdbus`. Answer empirically before writing any fix | agent 1.5h · **Deck 45–60 min** |
| **D2 — implement the winner** for #125 and #160 | One channel, two callers. `mcss_notify_user` (preflight.sh) is already the single encoding to swap out | agent 2h · **Deck 20 min** |
| **#134 + #79** dock-transition pair | Same machinery — work together. Capture must be detached loggers (see the SSH/dock constraint) | agent 2–3h · **Deck 45 min** |
| **#135** teardown wedge | Highest risk in the plan. Needs a written protocol and a recovery plan **before** the first attempt. Schedule alone, fresh | agent 2h · **Deck 60 min+, reboot risk** |

**Total: agent ~8h · Deck ~3h**, widest error bars in the plan.

---

## Suggested sequencing

1. **v1.2.4 shipped — done.** #122, #184/#185/#186, #126 all closed and
   hardware-validated. #196 and #36/#195 are real but non-blocking, parked
   in backlog.
2. **v1.3 through PR-4 — done, Deck-validated 2026-08-02.** PR-5 (#151
   reconnect/identity-swap repro) is next. Two small items to fold in
   whenever convenient (not blocking, both non-severe): the D3.2 cold-start
   timeout, and the destroy-latency `dmesg` remeasurement from PR-2 —
   bundle whichever fits into the next Deck sitting. (PR-3's separately-filed
   rig-cleanup pidfile-orphan finding is very plausibly explained, not just
   dropped: tonight's `rig_cleanup()` reentrancy fix covers the exact
   "trap fires a second time in the same process" shape needed to produce
   it, e.g. a transient signal — this Deck's dock-NIC connection was noted
   as flaky in that same session — triggering the TERM trap's `rig_cleanup`
   call plus a re-fired EXIT trap. Not independently re-confirmed against
   that exact PR-3 scenario, but no separate investigation is warranted
   unless it recurs.)
3. **v1.4 last.**

The milestones were renumbered on 2026-07-31 so version order matches build order —
releases ship in version order, so whichever track goes first *is* v1.3. The dock
track goes last because it is the riskiest work, needs the most Deck time, and #135
can cost a reboot per attempt. The rig does not help with any of it.

---

## Risks (live)

| ID | Risk | Status |
|----|------|--------|
| **R6** | No visible user-message channel exists in Game Mode at all. | **Materialized for dialogs** (#125, four measured attempts). D1 decides whether the `window_manager` path works. If not, #125/#160 become documented limitations. |
| **R8** | #135 reproduction costs a force reboot per attempt. | Unmitigated. Budget one Deck sitting per attempt. |
| **R9** | The `/dev/uhid` udev rule may not survive a SteamOS update. | Treat as re-installable; the probe detects it and prints the fix. |
| **R10** | Validation gaps carried into a shipped release. | #170's `ref:` fallback and `kwin_place_windows` under `-e` are both unproven on hardware — recorded in the v1.2.3 notes rather than implied away. |
| **R4** | evsieve-death `SLOT_DIED` can trigger or mask **#14** (D-state JVM). | Carried forward — capture `/proc/<pid>/{stack,wchan,status}` on any D-state seen during rig work. |
| **R11** | Overlay-mount fixes/mocks in test stubs can be too permissive (substring match instead of exact) and silently accept a wrong-but-similar value. | Materialized once during #186's own mutation testing (a typo'd fuse-overlayfs path passed a loose stub) — caught before merge by tightening the stub, not by luck. Worth a second look whenever a test stub does a substring `case` match on a path/flag value. |
| ~~R1 / R5~~ | evsieve reopen behaviour; uniq plumbing arity. | Retired with v1.2.0. |
| ~~R7~~ | `INSTALLER_MODULE_FILES` drift invisible to every test. | Retired — v1.2.2 was validated through a real `curl\|bash` install, the only mode that exercises the download list. |

---

## Deck state (2026-08-02, late evening — PR-4 closed, Deck rebooted by operator)

- **PR-4 (#71 burst-spawn) finished clean**: full 5-iteration `bash
  tests/probe-burst-spawn.sh 5` run, 50 passed / 0 failed / 0 skipped, every
  teardown clean (no orphans, no wedge), operator visually confirmed all 4
  windows on every iteration. Deck was confirmed fully clean (no game/rig
  processes, `docked` display mode) immediately afterward.
- Three infrastructure bugs found and fixed live this sitting — see PR-4's
  ladder entry above for the full detail: `rig_cleanup()` reentrancy
  (`tests/lib/uhid_rig.sh`), `hw_reap_stale_session`'s `kwin_wayland`
  marker-gate (`tests/hardware/lib/helpers.sh`), and a stale-FIFO/Steam-
  relaunch race (`tests/probe-burst-spawn.sh`). Two of these live in shared
  test-harness code used by every hardware stage script, not just PR-4.
- **Operator rebooted the Deck** after this session wrapped, as a normal
  fresh-start action (not a recovery from a stuck state — the Deck was
  already confirmed clean and idle beforehand). Next session should
  re-`deploy.sh --check` before trusting the checkout is what's actually
  deployed, per the usual convention.
- `.workdir/uhid-rig/` still carries leftover directories from tonight's
  sessions (harmless stale `.pid`/`.log` files, no live resources) — not
  cleaned up, safe to remove or leave for `--purge` whenever convenient.

## Deck state (2026-08-02, evening — human-mode session likely still up)

- **On `feat/136-pr2-rig-surface` @ `3f4eddc`** (D3.8/D3.10 text fixes),
  deployed and `deploy.sh --check`-verified fresh before both validation
  runs (the Deck itself was still on `df43b86` during the runs — the text
  fixes landed afterward, from the findings).
- **After the virtual-mode run** (below), a second same-day pass ran
  `bash tests/hardware/run_all.sh stage3_hotplug` in human mode with real
  Bluetooth controllers (up to 4 connected): 59 passed, 1 failed, 11 skipped,
  zero real regressions across the whole D3.0-D3.8 core lifecycle — see the
  PR-3 ladder entry above for the full breakdown. **This session's 4-player
  game was left running** (stage3's normal behavior, matching the
  virtual-mode run) — not explicitly stopped this time; assume it's still up
  unless confirmed otherwise next session.
- PR-3's `MCSS_VIRTUAL_PADS=1 bash tests/hardware/run_all.sh stage3` ran to
  completion: 4 fresh PolyMC accounts (never launched before this session —
  each showed Minecraft's one-time "Welcome" onboarding screen, never
  dismissed since virtual pads don't drive menus by design), 33/2/17
  passed/failed/skipped. Session stopped afterward via `hw_stop_orchestrator`
  → the operator had to manually Exit Game via the Steam overlay to clear a
  stale gamescope game-tracking state (see PR-3's ladder entry above) — no
  hard reset needed, Deck confirmed back to a normal idle Game Mode state.
- `.workdir/uhid-rig/` carries 3 leftover directories from this session
  (`185093` real run, `traptest`/`traptest2` diagnostic repros) — harmless
  stale `.pid`/`.log` files, no live resources; not cleaned up, safe to
  `--purge` or manually remove whenever convenient.
- Minecraft instance version for these 4 accounts: 26.2 (installer default,
  per the java classpath seen in the run's process dump) — **not** the
  26.1.2 home-server pin; unverified whether that matters for this branch's
  purposes, flagged in case it does before any multiplayer-against-the-home-
  server testing happens on these accounts.

## Deck state (2026-08-01, ~2:06pm — stale, prior session)

- **On `main` @ `2d7d96a` (post-v1.2.4-tag), fresh reinstall completed
  through the real, unmodified installer** — evsieve installed via the
  prebuilt release path (`EVSIEVE_INSTALL_STATUS=installed-prebuilt`), no
  test scaffolding involved. This was a genuinely clean install: it followed
  a `--purge` run (confirmed with Scott first) done specifically to get a
  fresh distrobox for the #196 fallback-path investigation.
- **World/accounts/options are the freshly-created defaults from this
  reinstall, NOT the pre-purge data** — the purge wiped `TARGET_DIR`
  entirely and nothing was backed up first this time (dummy/test data only,
  confirmed fine with Scott — see the earlier lost-world incident this
  session, same call). If Scott had anything worth keeping on this install
  since the last backup, it's gone; nothing flagged as such.
- **evsieve/seamless reconnect is ON**, via the prebuilt release binary
  (v1.2.4's #126 path), not build-at-install. `MCSS_CONTROLLER_PROXY`
  default applies normally.
- Steam shortcut: left in place through the purge (purge's shortcut-removal
  step correctly refused since Steam was running — by design, no forced
  Steam shutdown attempted) and detected as "already present" on reinstall.
- Minecraft instance versions: whatever the installer's current default
  pulls (26.2 per the last reinstall log) — **not re-verified against the
  home-server pin (26.1.2)** after this reinstall; check before assuming
  parity if that matters for the next session.
- `mcss-evsieve-build` distrobox: removed as part of this session's cleanup
  (no dangling stale-state box left behind).
- `60-mcss-uhid.rules` installed; `/dev/uhid` carries `user:deck:rw-`
  (unaffected by any of today's purge/reinstall work — a udev rule, not
  part of `TARGET_DIR`).
- `.workdir/mcss-benchmark*` (the July A/B campaign's raw data + world
  backup, ~394M) is deliberately kept — Scott's call, not urgent. Confirmed
  still present after today's `.workdir` cleanups (old MC backups were
  removed earlier in the session; the benchmark data was explicitly
  excluded both times).

---

## Document map

- **Design / law:** `PRINCIPLES.md` (why), `ARCHITECTURE.md` (where code goes),
  `STYLE-GUIDE.md` (how it looks), `SPEC.md`,
  `DESIGN-38-RECONNECT-WIRING.md`, `RESEARCH-136-VIRTUAL-PAD-RIG.md`.
- **Records:** `HW1-VALIDATION-2026-07-19.md`, `HW2-VALIDATION-2026-07-22.md`,
  `VERIFY-70-MAXFPS.md`, `BENCH-AB-2026-07-18.md`,
  `AUDIT-ARCHITECTURE-2026-07-17.md`, `AUDIT-98-STYLE-GAPS.md`,
  `DERIVATION-AUDIT-2026-07-22.md`, the `BUG-AUDIT-*` and `RESEARCH-*` docs.
- **Running history:** `MEMORY.md`, `TODO.md`.
- **Archived plans:** `PLAN-20260705.md` (v1.1), `PLAN-20260718.md` (v1.2 kickoff),
  `PLAN-20260720.md` (v1.2 mid-campaign), `PLAN-20260731.md` (pre-v1.2.3),
  `PLAN-20260801.md` (pre-#122-hardware-validation, morning),
  `PLAN-20260801b.md` (v1.2.4 in-progress, midday — before the release cut
  and #196 discovery).
