# MinecraftSplitscreenSteamdeck — Canonical Plan & Roadmap

**This is the single source of truth for where the project stands and where it is
going.** It supersedes the per-campaign `PLAN-V1.x` docs (now archived — see
[Versioning](#versioning) and [Document map](#document-map)).

**Last updated:** 2026-08-02 · **Repo:** `aradanmn/MinecraftSplitscreenSteamdeck`
· **Active cycle:** v1.3 (virtual pad rig) — PR-2 (#197) Deck-validated; PR-3 (stage3_hotplug automation) built, **not yet Deck-validated**

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
| **v1.3** | Virtual pad rig. **In progress.** PR-1 subsumed by PR-0 (#158, already shipped it). PR-2 (rig control surface) opened as #197 — 93/93 CI, 7/7 mutations confirmed red, **Deck-validated 2026-08-01**: core lifecycle confirmed on real hardware, one earlier "burst enumeration broken" scare fully explained (MAX_PLAYERS cap contention, not a bug), one destroy-latency question left genuinely open pending a `dmesg`-based remeasurement. PR-3 (`stage3_hotplug` automation behind `MCSS_VIRTUAL_PADS`) **built 2026-08-02, not yet Deck-validated** — default human-prompted path is untouched; the virtual-pad path needs its first real run on hardware. |
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
| **PR-3** automate `stage3_hotplug` behind `MCSS_VIRTUAL_PADS` (human mode stays default) | **Built, agent-side, 2026-08-02 — not yet Deck-validated.** Every "plug in controller N" gate in `tests/hardware/stage3_hotplug.sh` now has a virtual-pad arm (`rig_create_pad`/`rig_destroy_pad`/`rig_wait_for_pad`), added as a new `if _stage3_virtual_mode; then … elif hw_prompt …` branch — every human-mode branch is byte-identical to what shipped before this PR, so the default (unset/0) path is unchanged. D3.0 additionally does `rig_init` + `rig_install_traps` (EXIT/INT/TERM) so pads survive across stages 3→5 (run_all.sh sources every stage into one shell) but still get reaped on process exit. Gameplay/visual checklists (no human pilot in virtual mode) auto-skip via `_stage3_skip_checklist_if_virtual`, pointing back at the automated geometry/property assertions that already cover the step. Chaos tests D3.11/D3.12 get full virtual equivalents (rapid destroy/create cycling; whole-rig destroy+recreate for the "hub drop" case). D3.10 (monitor-kill) automates the *action* (cycle one pad via the rig) but deliberately leaves the *verdict* an `hw_skip`, not a guessed pass/fail — no validated automated check exists yet for "did the slot cycle correctly" and inventing one without hardware validation would be confidently wrong (PRINCIPLES #3/#4). **Next: run it on the Deck** (`MCSS_VIRTUAL_PADS=1 bash tests/hardware/run_all.sh stage3`) to confirm the flag path actually behaves like the (unvalidated-by-construction) code reads. | agent ~3h (spent) · **Deck 40 min (still owed)** |
| **PR-4** #71 burst-spawn repro + fix | Not started. | agent 2h · Deck 30 min |
| **PR-5** #151 repro + quiesce-then-repoint fix | Not started. | agent 3h · **Deck 45 min** |
| **#70** benchmark pilot | Not started — also blocked on the open-loop-timed-input methodology decision (§5 of the research doc). | agent 4h+ · **Deck 3h+** |

**Remaining: agent ~14h · Deck ~6h** (PR-1's 2h/15min came off the estimate — folded into PR-0's cost).

**One gap from PR-0:** V8 returned `SAME_NODE`, not `RENUMBERED` — destroy+recreate
reused the same `eventN`, so the renumber case (#112's mechanism, and what #151 is
about) is still untested. Forcing it needs the 3-pad trick; that is PR-5's job.

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
2. **v1.3 through PR-3** — the rig starts paying back Deck time the moment
   `stage3_hotplug` automates. **PR-3 is now built (agent-side); next Deck
   sitting should validate it** (`MCSS_VIRTUAL_PADS=1 bash tests/hardware/run_all.sh
   stage3`) before trusting it for real, per PRINCIPLES #3 — untested-on-hardware
   test-harness code is still untested. The destroy-latency `dmesg` remeasurement
   from PR-2 (see `docs/RESEARCH-136-VIRTUAL-PAD-RIG.md`/memory) is a good thing
   to bundle into the same sitting.
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

## Deck state (2026-08-01, ~2:06pm — Deck likely powered off now)

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
