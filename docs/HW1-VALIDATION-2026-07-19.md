# HW-1 — v1.2 M0+M1 hardware validation (2026-07-19)

> Deck session, operator Scott, orchestrated remotely over SSH (Game
> Mode, DISPLAY=:0 authless gamescope). Test target:
> `integration/hw1-20260719` = main + all six open PRs (#104 #106 #107
> #108 #109 #110), proxy flag OFF — the exact M1 exit configuration.
> All six PRs merged to main immediately after this session.

## Verdict summary

| Check | Result |
|---|---|
| H1 fresh install from branch | PASS — 4 instances, MC pinned 26.1.2 (server pin), fresh evsieve build path exercised |
| H2 `evsieve --version` on SteamOS host | PASS — 1.4.0, exit 0 (bookworm cargo 1.63 MSRV assumption held; no image bump) |
| H3 stamp | PASS — `commit=ebd7efe1…` `patch_sha256=9ec2cd9d…` |
| H4 probe P0/A/B vs built binary | PASS ×2 runs — P0 uinput open; A node identity STABLE across gap; B stream fidelity OK. BONUS_STEAM_GRAB=STARVED (grab-before-Steam / nested-session requirement confirmed) |
| Full stage0–stage5, flag OFF | **144 passed / 7 failed / 14 skipped — all failures known/expected (below); v1.1-behavior-unchanged criterion MET** |
| H5 D2 repoint verdict | **UNDECIDED — blocked by #112** (evsieve death after BT reopen), not a repoint result |
| H6 virtual identity across battery-death | CHANGED (post=NONE) — honest downstream artifact of #112, non-vacuous detection worked |
| H7 teardown cleanliness | PASS (probe cleanup left no evsieve/dangling links; module liveness contract escalated correctly) |
| H8/H9 CONTROLLER_ADD uniq | PASS via stage1 S1.3 on the integrated branch: docked eligible-pad line carries the DS4's MAC uniq as field 5 (`a0:5a:5e:d0:8a:dc`); handheld line 4-field legacy shape preserved |

## The 7 stage failures, adjudicated

- `D3.8[2]` — **#62 expected fail** until #38 PR4 (static dev-binds can't
  reattach). The before-picture v1.2 exists to fix.
- `D3.10` — known **#16** (hotplug does not survive a controller-monitor
  kill; heartbeat restarts the monitor but the slot never cycles).
- `D3.7[4]` — operator input slip (Enter instead of `y`); the harness's
  own geometry asserts in the same run prove no slot re-shuffled.
- `I4.1` ×4 — stale harness check, filed **#111**: counts /dev/input fds
  on the bwrap supervisor and expects an event+js pair; raw binding
  dev-binds js only and the fds live in the java child. Real isolation
  evidence passed (I4.2 unique nodes, I4.3 operator cross-input check).

Skips: InputPlumber absent (non-fatal), splitscreen.properties retired
checks, D3.9 (no 5th pad), D3.12 hub-yank + USB-chaos steps (BT pads,
2-port dock), I4.4 (needs root), C5.5 (orchestrator PID untracked in
per-stage invocation).

## Highlights beyond the checklist

- **Stage2 8/0** including clean exit: slot cleared instantly on quit,
  zero orphans. **Stage5 6/0**: watchdog cleared a SIGKILLed java in 4s
  and a SIGKILLed bwrap in 13s; slot reuse after crash confirmed.
- 4-up docked quad at 1280x720 nested with per-quadrant input isolation
  operator-confirmed at 2P/3P/4P; sticky slots through a P2 disconnect
  (#37 contract) with no reflow — PR #100's #83/#84 fixes validated.
- Installer UX (PR #110) observed live: mod prompt auto-skipped
  ("All 7 mods are required"), desktop launcher skipped. #95 re-assert
  line observed per instance (PR #107).
- In-game input sanity: left stick moves the player, right stick the
  camera, on the correct instance only.

## D2 status and the #112 finding

The D2-CONFIRM probe validated the carried evsieve patch on hardware for
the first time: the BT reconnect hit the first-EACCES blueprint race and
the bounded retry rode through it. Then BT re-enumeration returned the
DS4 with different capabilities ("capabilities of the reconnected device
are different than expected"), evsieve logged the reconnect, and **died
silently within ~2 minutes** (no coredump/journal record). H5 therefore
reports the module's correct dead-proxy escalation, not a repoint
verdict.

**Design consequence adopted now, independent of the eventual D2 vs
D2-alt outcome: PR4 must include watchdog supervision of per-slot
evsieve.** Real BT reconnects can kill the proxy even when the reopen
initially succeeds.

Next step for the verdict: evsieve 1.4.0 source read of the
post-mismatch reopen path (#112) → patch v2 (rebuild blueprint on
mismatch / delay reopen until capabilities settle) or accept D2-alt
(stop+start on reconnect). Rerun is a 5-minute pure-BT probe.

## Issues filed this session

- **#103** orchestrator suite rewrite (stale assertions, kill-scoping,
  stderr exec bug) — plus the fixture-PID/pid_max hardening already
  merged via PR #101.
- **#105** 4 stale controller_monitor tests vs the raw-binding default.
- **#111** stale I4.1 fd-count check (bwrap vs java, event+js vs js).
- **#112** the D2 blocker above (includes the probe-driver fix list:
  bounded waits — the post-reconnect phase hung until ^C; polling
  disappearance check; per-transport prompts — PS-hold does not power
  off a cabled DS4; progress indicators per the new convention).

## Session learnings folded into the toolchain

- gamescope's Xwaylands are authless; Desktop Mode's Plasma Xwayland is
  auth-bearing — hw_detect_display now handles both (PR #108).
- An idle gamescope root has no `_NET_ACTIVE_WINDOW`; reachability
  probes must be focus-free (PR #108).
- Module constants must be re-source-safe (PR #109 + test).
- Operator prompts must be unmistakable and every internal wait must
  show progress/countdown — retrofit batch queued; stage6 needs a
  running-session guard (it spawned a fresh session on top of a live
  4-up and required a Deck reboot).
