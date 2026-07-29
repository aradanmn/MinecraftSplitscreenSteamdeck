# Research — a virtual gamepad rig: automated multi-player testing and a scripted benchmark pilot

> Recon pass, 2026-07-29. Feeds #136 (virtual controller rig), and touches
> #71 (burst-spawn race), #151 (reconnect node-swap), and the v2 benchmark
> protocol in `tests/benchmark/RUNBOOK.md`. Verification status is marked per
> claim: **[kernel-src]** = read from the mainline kernel source/uapi headers;
> **[repo]** = read from this codebase; **[inferred]** = follows from the two
> above but not yet observed on our hardware; **[needs-Deck]** = must be
> confirmed on the Deck before anything is built on it.

## The question

#136 asks for virtual gamepads so the rig can drive up to 4 players without
humans juggling controllers. Two use cases, and they turn out to have very
different difficulty:

1. **Structural testing** — hotplug, tiling, isolation, the #71 burst-spawn
   race, and reconnect identity (#38/#151). Pads exist, appear, and vanish.
2. **Benchmark piloting** — pads that *play*: join the world and drive players
   through a fixed sequence so a performance run is repeatable without four
   humans flying by hand.

## Verdict

**Build it on `uhid`, not `uinput`.** The obvious tool (`uinput`, which #136
suggests) cannot set a device's `uniq`, which is the identity field the whole
#38 reconnect stack keys on — and every `uinput` device would additionally
collapse into a single pad under our enumerator's dedup. Both problems vanish
with `/dev/uhid`, which takes a caller-supplied `uniq` and is the same
interface BlueZ uses to create real Bluetooth pads. A uhid-backed virtual pad
is structurally indistinguishable from a real BT controller, so it exercises
the production path rather than a parallel one.

**Use case 1 is straightforward. Use case 2 is worth doing but has one real
methodological hazard** (§5) that has to be designed for, not discovered
mid-campaign.

---

## 1. `uinput` is the wrong interface — two independent blockers

### 1.1 It cannot set `uniq`, so a virtual pad can never RESUME

`struct uinput_setup` carries `id`, `name`, and `ff_effects_max` only; the
ioctl list includes `UI_SET_PHYS` but has no uniq equivalent **[kernel-src:
`include/uapi/linux/uinput.h`]**. A `uinput` device therefore always reports an
empty `U: Uniq=`.

That is fatal for reconnect testing. `slot_find_by_uniq` returns nothing for an
empty key by deliberate design — "Empty uniq NEVER matches (a blank key must
never sticky-collide)" (`modules/slot_manager.sh:97`) — so `slot_claim` skips
the RESUME branch entirely (`slot_manager.sh:210`) **[repo]**. A reconnecting
`uinput` pad would fall through to ADOPT-an-orphan-within-grace: a real code
path, but *not* the one v1.2 ships. #151's swap race, which is specifically
about MAC-keyed identity racing a repoint, could not be reproduced at all.

### 1.2 Every `uinput` pad collapses into one under enumeration

`_list_raw_external_pads` step 6 dedups by "parent device": it takes the sysfs
path, strips a trailing `/input/inputN`, and keeps only the **lowest jsN** per
key (`modules/controller_monitor.sh:596`) **[repo]**. `uinput` devices live at
`/devices/virtual/input/inputN`, so that strip yields `/devices/virtual` —
identical for every one of them **[inferred]**. Create four pads, enumerate
one.

This has never bitten in production because nothing currently reaches step 6
with a virtual-bus sysfs path: Steam's `28de` virtuals are dropped by the
vendor gate (step 3) and our own evsieve virtuals by the `MCSS-slot*` gate
added in #149 (step 3b) **[repo]**.

---

## 2. `uhid` solves both, and is what real Bluetooth pads already use

`struct uhid_create2_req` contains `uniq[64]` alongside `name[128]`,
`phys[64]`, the report descriptor, and the bus/vendor/product/version fields
**[kernel-src: `include/uapi/linux/uhid.h`]**. HID core propagates it to the
input device: `hidinput_allocate()` assigns `input_dev->uniq = hid->uniq`
directly alongside `->name` and `->phys` **[kernel-src:
`drivers/hid/hid-input.c`]**. So a uniq we choose at create time lands in
`/proc/bus/input/devices` as `U: Uniq=`, which is exactly what
`parse_input_device_blocks` reads as field 8 (#38 PR3) and what
`slot_manager` keys identity on **[repo]**.

Give each virtual pad its own fake MAC (`aa:bb:cc:00:00:01`, `…02`, …) and
they are four distinct identities to the entire stack.

**This is not an impersonation trick.** BlueZ creates Bluetooth HID devices
through `/dev/uhid`; a uhid-backed virtual pad takes the same kernel path a
real BT DualShock takes. Our own code already assumes this shape — the dedup
comment notes the parent key "collapses an 8BitDo dual-js under one **uhid**"
and that "a BT uhid key is per-CONNECTION" (`controller_monitor.sh:479-481`)
**[repo]**. Each uhid instance gets its own device directory, so §1.2's
collapse does not occur and **no production code change is required**
**[inferred, needs-Deck]**.

### 2.1 Reconnect becomes scriptable

Destroy a uhid device and recreate it with the same `uniq` and you have
reproduced a Bluetooth pad power-cycling: new `inputN`/`eventN`, same identity.
That is precisely the RESUME path v1.2 ships, driven from a script instead of
by pulling a battery.

#151 becomes reproducible on demand: destroy two pads, recreate them in the
opposite order so each lands on the other's freed `eventN`.

### 2.2 Descriptor choice — start generic, not DS4

Supply a minimal report descriptor using `Usage(Gamepad)` with our own VID:PID.
`hid-generic` binds it, and the buttons map into the `BTN_SOUTH` range that
`_has_gamepad_buttons` gates on (`controller_monitor.sh:441`, accepting
`BTN_SOUTH 0x130` or `BTN_JOYSTICK 0x120`) **[repo]**. Impersonating a real
`054c:05c4` instead pulls in `hid-playstation`, which expects genuine DS4
report layouts and spawns the motion/touchpad sub-nodes — interesting later for
#112-shaped multi-node tests, wrong place to start.

Give each pad a **distinct product ID**, or step 8's dual-transport guard emits
a loud warning about four identical VID:PIDs (harmless — it never
auto-collapses — but it pollutes the logs) **[repo]**.

### 2.3 Implementation shape

uhid is a chardev you `write()` structs to — no ioctls at all — so a
dependency-free Python helper is if anything simpler than the uinput
equivalent, and needs no compiler or container on the immutable SteamOS
rootfs. Injection is packing a few bytes per report.

**Open item: `/dev/uhid` is typically root-only.** The rig likely needs `sudo`
(the `deck` user has passwordless sudo from the #124 work) or a udev rule.
Confirm before building **[needs-Deck]**.

---

## 3. Use case 1 — what the structural rig covers

| Target | Today | With the rig |
|---|---|---|
| `stage3_hotplug` | Human prompted to "Plug in a SECOND/THIRD/FOURTH external controller" (`stage3_hotplug.sh:133,167,205`) | Create pads on a timer, assert geometry per step |
| #71 burst-spawn | Near-impossible by hand — needs 4 pads arriving near-simultaneously | Create 4 pads in one burst pre-launch |
| `stage4_isolation` | 4 humans pressing buttons on cue | Scripted per-pad input, assert only the owning instance reacts |
| #38 RESUME / #151 | Battery-pulling real DS4s | Destroy/recreate by uniq, in a chosen order |

---

## 4. Use case 2 — the benchmark pilot

The v2 protocol (`tests/benchmark/RUNBOOK.md`) already specifies everything
except who holds the controller. Cycles run `S1_idle` → `S2_flight` (180s,
"each player creative-flies fast and level in their assigned bearing … then
turns around and flies back") → `S3_idle2`, with a bearings table per player
count and a `/tp` hop to unexplored territory so every flight generates fresh
chunks **[repo]**. `sampler.sh` collects system metrics, MangoHud collects
per-screen FPS, `summarize.sh` reduces it.

**So the rig replaces the pilot, not the protocol.** The bearings table,
segment marks, samplers and summarizer all stay as-is.

### 4.1 Don't drive the menus — skip them

Navigating title → multiplayer → server with a virtual stick is the most
fragile thing we could build: it is timing-dependent, and it breaks on any
menu-layout change from a Minecraft or Controlify update.

Instances launch via `PolyMC.AppImage -l <instance> -a <account>`
(`instance_lifecycle.sh:379,564`) **[repo]**. The MultiMC-family CLI carries a
`--server` flag for joining a server on launch, and modern Minecraft has
`--quickPlayMultiplayer` — either removes menu navigation entirely
**[needs-Deck: confirm against the Deck's PolyMC AppImage `--help` and the
26.1.2 arg set]**. World/gamerule setup (`/tp`, `advance_time false`) should
likewise stay command-injected as it is today, not typed with a gamepad.

That leaves the virtual pads responsible only for the part that genuinely
requires a controller: **in-world movement during the scored segments**.

### 4.2 Two wins beyond removing humans

**It fixes the heartbeat hack.** The Deck ramps clocks down when a session sees
no input, so `input-heartbeat.sh` taps an unbound F7 at each window via
`xdotool` every 8s. Its own header concedes the uncertainty: "Whether synthetic
X input actually defeats the ramp-down is verified at the MangoHud probe … if
it does not, fall back to pinning governors" **[repo]**. A uhid pad emits real
evdev input through the real path, so it defeats the ramp-down by construction
— and the hack can be deleted.

**It removes pilot variance.** "Flies fast and level" varies between humans and
between runs; that variance is currently sitting inside the A/B numbers as an
unquantified confound. Identical scripted input removes it.

### 4.3 What still needs a human

The soft gates are irreducibly subjective: smoothness 1–5, stutter reports,
audio crackling (`RUNBOOK.md` step 6). The rig gets the **hard gates**
(completion, RSS, swap, PSI, CPU, MangoHud FPS) running unattended; it does not
get you the perceptual ones.

---

## 5. The one real hazard — open-loop input under variable load

**This is the thing to design for up front.** Holding "fly forward" for 90s
does not do the same amount of work on every run. Distance covered depends on
how fast the game is running, so a slower configuration flies *less far*,
generates *fewer chunks*, and therefore incurs *less load* — a negative
feedback loop that flattens precisely the differences an A/B is trying to
measure. A blind timed script is self-damping in exactly the wrong direction.

Note this hazard is *absent* from the current human-piloted protocol only by
accident: humans also fly slower under stutter. It is worth fixing either way.

Options, best first:

1. **Score by work done, not wall-clock.** Fly until a target coordinate or a
   target chunk count, and record the *time taken*. Load per unit work becomes
   comparable by construction.
2. **Keep time-boxed segments but record distance travelled as a covariate**,
   so "branch flew 20% further at the same FPS" is visible in the results
   instead of silently confounding them. Cheaper; preserves comparability with
   the existing v2 numbers.
3. Gate phase transitions on **log-line events** from each instance's
   `latest.log` rather than fixed sleeps, so setup steps never race under load.

Recommendation: (2) plus (3) for the first campaign — it keeps continuity with
the existing dataset — then evaluate (1).

### 5.1 Determinism caveats that remain

A fixed-seed world (`BenchWorld`, plus the `bench-baseline-2026-07-19` release)
and the gamerule locks already in the protocol get runs *comparable*, not
identical. Mob spawns, random ticks, and chunk-load ordering still vary. Treat
results statistically across cycles — which the v2 protocol already does.

---

## 6. Recommended sequencing

Ship the boring half first; the pilot is where the unknowns are.

1. **Confirm the Deck facts** (§2.3, §1.2, §4.1): `/dev/uhid` permissions; that
   a uhid pad enumerates with a distinct sysfs parent and a populated `U:
   Uniq=`; that `--server`/quickPlay works from our launch path.
2. **Pad primitive** — create / destroy / inject, dependency-free, `.workdir/`
   resident. Prove it by making one pad spawn a player.
3. **Structural rig** — automate `stage3_hotplug`, then the #71 burst case.
   Highest value per unit effort, and no new methodology.
4. **Reconnect rig** — destroy/recreate by uniq; reproduce #151 on demand.
5. **Benchmark pilot** — only after 2–4 are trustworthy, and with §5 settled
   before the first campaign rather than after.

## Open questions

- `/dev/uhid` permissions on SteamOS — sudo, udev rule, or already accessible?
- Does Steam mint a `28de` virtual for a uhid pad in Game Mode as it does for a
  real one? Expected yes, and harmless (vendor-gated out), but it should be
  observed rather than assumed.
- Does evsieve grab a uhid-backed pad identically to a real one under
  `MCSS_CONTROLLER_PROXY=1`? Expected yes — same evdev surface — but it is the
  assumption the whole rig rests on.
- Which report descriptor gives the cleanest Controlify behaviour? Irrelevant
  for hard gates, relevant if the pilot ever needs to drive a menu after all.
