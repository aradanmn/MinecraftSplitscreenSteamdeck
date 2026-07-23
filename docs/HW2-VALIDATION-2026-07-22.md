# HW-2 Validation — 2026-07-22

> Operator: aradanmn (on-Deck). Docked, **official Steam dock + projector**, Game Mode
> (gamescope), orchestrated over SSH. Target: `main` @ `7d37532` (deployed via `./deploy.sh`,
> `--check` clean). Controllers: up to 4× DS4 over **Bluetooth** (no cabled pads).

## Verdict summary

| Check | Result |
|---|---|
| Deploy `main` to Deck + freshness | PASS (`--check` clean, 13 files) |
| Dynamic hotplug (BT DS4 ×4) | PASS — slots 1→4 hotplugged cleanly, layout reflowed each time |
| **#111** stage4 I4.1 (java-child fd isolation) | **PASS ×4** — each game holds only its own `jsN` (js1/js3/js5/js7), 0 leakage |
| stage4 overall | 5 PASS / 0 FAIL / 2 SKIP (I4.3 operator + I4.4 root-only skipped) |
| **#83** geometry on external display | PASS — correct tiling at 2/3/4-up (operator-confirmed) |
| **#84** sticky slots on controller DC | PASS — P2 pad disconnect → `CONTROLLER_REMOVE → PRESERVED`, slot stayed active, window persisted, no reflow |
| **#62(b)** isolation kernel-enforced | CONFIRMED — sandboxes expose only own node (opposite of the 2026-07-06 app-layer-only finding) |
| **#70** FPS cap | CONFIRMED applied (all 4 instances `maxFps:60`); 4-up ~38% CPU, GPU ~25% avg, VRAM 947/1024 MB |
| **#60** supervised reap | Supervisor now **runs** (`[supervise_reap] entered`) — never did pre-fix; clean exit, 0 orphans (stubborn-reap path not stress-tested) |
| **#135** teardown wedge | Did **NOT** recur on a clean exit → wedge is **display-flip-specific**, not general |

**Issues closed by this run:** #111, #83, #84, #60. Updated: #62.

## The opening crash (and what it taught us)

First launch attempt cascaded into a lockup requiring a force reboot. Root-caused from the
saved log bundle:

1. A **single spurious `/sys/class/drm/card0-DP-1/status = disconnected`** read — the
   projector was physically connected and displaying the whole time (DP-1 read `connected`
   immediately before and after).
2. `dock_detection` has **no debounce** → it emitted `DISPLAY_MODE_CHANGE handheld` on that
   one read → orchestrator switched to handheld and **moved MC to the internal panel**, where
   it froze. (**#133**)
3. DP-1 read `connected` again and `DISPLAY_MODE_CHANGE docked` fired, but the
   **handheld→docked path is a no-op** → MC never returned to the projector. (**#134**)
4. On quit, the nested-session teardown **wedged** → no output anywhere → force reboot. (**#135**)

**Not a regression from this session's update** — verified `dock_detection.sh` /
`orchestrator.sh` were unchanged in the 23-commit jump (all test-harness/docs/evsieve). The
trigger was the Deck's known intermittent DP flicker coinciding with an active docked session;
a **dock power-cycle** cleared the wedge and DP-1 then held rock-steady (verified: 0 kernel
DP events + a 90s soak of 45/45 `connected`) for the rest of the session.

**New issues filed:** #133 (dock debounce — the fix that would have prevented the crash),
#134 (handheld→docked restore), #135 (teardown wedge), #136 (virtual-controller rig idea).

## Notable UX gap observed

A disconnected controller leaves that player's session **uncontrollable** — with no input
bound, P2's instance could not be quit by the operator, and a reconnect would not re-attach
to slot 2 (static bwrap bind). This is exactly the gap **#38** (seamless reconnect) exists to
close — see the roadmap note below.

## Resource profile (4-up, capped @60, docked)

- CPU ~38% used (58% idle), load ~7.4 — big headroom.
- GPU bursty 0–88%, ~25% avg (renders a frame then idles between capped frames).
- RAM 12/14 GB (6.4 GB across 4 JVMs), VRAM **947/1024 MB — the real ceiling**.
- Confirms #70's value: capped 4-up ≈ 38% CPU vs the weekend's ~92–94% uncapped.

## Roadmap note (v1.2)

The v1.2 headline is **#38 — seamless controller reconnect**. This session validated the
**foundation** (#37/#84 sticky slots, #62/#111 isolation, hotplug) but the **reconnect** half
is not built and is **blocked by #112** (evsieve dies ~2 min after a BT reconnect). #112 is
the critical path and has not moved since HW-1. See the session discussion.
