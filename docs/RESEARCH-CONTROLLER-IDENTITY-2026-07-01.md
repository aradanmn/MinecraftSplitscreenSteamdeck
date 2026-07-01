# Research — how Steam identifies a reconnected controller, and what we can do

> Multi-agent research pass, 2026-07-01. Feeds #38 (seamless reconnect) and the
> gated `RAW-CONTROLLER-BIND-PLAN.md`. Pure research — no code changed here.
> Confidence is called out per claim; several primary sources 403'd to the
> research agents' fetchers and are marked as search-snippet-level accordingly.

## The question

If a controller disconnects mid-session and is reconnected, the kernel hands it
a **new** `/dev/input/eventN`/`jsN` minor (or, worse, an old minor can be reused
by an unrelated device). Our bwrap sandboxes bind a slot to a device node at
launch, so a reconnect can't get back into its running instance. Steam visibly
manages this — replug a DS4 mid-game in Big Picture/gamescope and the game
keeps working. How?

## Short answer

**Steam/SDL do not solve per-unit re-identification — they solve it by never
needing it.** The abstraction layer (a persistent virtual pad) stays open the
whole time; the *game* never sees a disconnect. Games identify controllers by
an SDL **GUID that is a function of static device metadata (bus/vendor/product/
version/name), not a per-unit serial** — so two identical pads produce the
*same* GUID, and a reconnect trivially "matches" because there was never a
real identity check. Separately, Linux/HID *does* expose data that stably
identifies one physical unit across replug for most gamepads (the `uniq`
field), but that's not what Steam Input or SDL primarily lean on.

## 1. How SDL builds controller identity (confirmed, primary source)

`src/joystick/linux/SDL_sysjoystick.c` (current SDL, both SDL2/3) calls
`ioctl(fd, EVIOCGID, &inpid)` for `bustype/vendor/product/version` and reads
the device name, then builds a GUID via `SDL_CreateJoystickGUID()`
(`src/joystick/SDL_joystick.c`): a CRC16 of the name string, packed with
bus/vendor/product/version. **No serial, no per-unit data.** The HIDAPI
backend does the same. This means:

- The GUID is stable across replug/reboot for the *model* — which is exactly
  why `SDL_GameControllerDB` mapping works.
- Two identical units (two DS4s) get the **identical** GUID. SDL cannot tell
  them apart by GUID alone.
- SDL *does* also expose a serial via `SDL_GetJoystickSerial()`
  (`SDL_UDEV_GetProductSerial` → udev's `ID_SERIAL_SHORT`), added in SDL
  2.0.14 — but this is a side-channel apps rarely use, and is frequently empty
  (see §3).

## 2. How Steam Input / InputPlumber actually handle reconnect (confirmed)

Two different mechanisms, and neither is "re-identify the exact unit by
serial":

- **Steam Input's virtual pad (`28de:11ff`)** is a stable uinput device that
  stays present for the whole session; the game only ever talks to it. This
  matches a **converged, independently-invented pattern** also used by
  MoltenGamepad, WiimoteGlue, `nexus_gamepad_uinput`, and Shadow's remote-play
  client (all confirmed via their own READMEs): keep one persistent virtual
  device open, and let *that* survive the physical device's disconnect — the
  consumer (game/emulator) never has to handle a hotplug event at all. This is
  exactly what our issue #38 proposes, and it's the industry-standard fix,
  not a novel idea.
- **InputPlumber** (SteamOS's Rust input daemon, `ShadowBlip/InputPlumber`,
  GPL-3.0+, shipped on SteamOS/Bazzite/ChimeraOS) matches *source* devices to
  a composite device using udev/evdev/hidraw matchers (vendor:product,
  `phys_path`, sysfs attributes) and, for Bluetooth, explicitly compares the
  evdev **`uniq` field against the Bluetooth MAC address** (`manager.rs`:
  `uniq.to_lowercase() == address.to_lowercase()`). Critically, it has a
  **`persist`** config option: a composite (virtual) device is *not* torn down
  when its source device(s) disappear, so a reconnecting source device is
  **reattached to the existing composite device** rather than spawning a new
  one — confirmed live in a real bug report (Legion Go 2 joycon dropout,
  issue #570: *"Found missing input device, adding source device evdev://event3
  to existing composite device"*). This is the "stable proxy + reattach by
  matcher" pattern, same shape as #38's proposal.

## 3. What real per-unit identity data exists on Linux (confirmed, with caveats)

- **`uniq`** (`/proc/bus/input/devices` `U:` line, udev `ID_UNIQ`) is
  transport-driver-populated, not universal. For Sony pads specifically
  (`hid-sony.c`, current mainline, confirmed by reading the source): Bluetooth
  reads the MAC straight from the HIDP `uniq` field; **USB also gets the
  controller's real internal MAC**, via feature report `0xf2` — so genuine
  DS4/DualSense units expose a stable per-unit MAC as `uniq` over *both*
  transports. This is a stronger result than expected.
- **USB serial descriptor is absent on genuine DS4/DualSense** (`iSerialNumber
  = 0x00`, confirmed via descriptor dumps) — so "USB serial" isn't the
  mechanism; the MAC-via-feature-report is.
- **Clone/counterfeit DS4 pads are a documented failure mode**: many don't
  implement the feature report, so the driver logs a MAC-read failure and
  `uniq` ends up empty/garbage — clones can collide with each other. This is
  real but device-model-specific, not universal.
- **Xbox/8BitDo evidence is weaker** — no confirmed per-unit serial guarantee
  found; community udev rules for these match VID:PID only, not serial,
  suggesting per-unit identity isn't reliably available for that class.
- **udev already has a persistent-naming scheme for this**
  (`/usr/lib/udev/rules.d/60-persistent-input.rules`, confirmed by reading the
  systemd source): `/dev/input/by-id/$ID_BUS-$ID_SERIAL-...` — but the same
  file shows the fallback: `ID_SERIAL=="" → ID_SERIAL="noserial"`. Two
  identical no-serial pads get the **literally identical** by-id symlink and
  collide. `by-path` symlinks are stable only if replugged into the same
  physical port.
- **Real-world precedent for keying on Bluetooth `uniq`/MAC exists**
  (`robfisc/controller-udev-rules`, confirmed): per-MAC udev rules
  distinguishing two identical 8BitDo pads over Bluetooth, e.g.
  `ATTRS{uniq}=="e4:17:d8:03:0a:00" → SYMLINK+="input/sn30proplus0"`.

## Ranked recommendation for this project

1. **Best near-term win, no kernel/daemon work: read `uniq` (the `U:` line in
   `/proc/bus/input/devices`, same field the raw-bind plan's parser already
   walks) and use it as a *soft* reconnect hint** — when a `CONTROLLER_ADD`
   arrives, check whether its `uniq` matches an already-known-but-missing
   slot's stored `uniq` before falling back to first-free-slot. This works
   for genuine Sony pads over USB *and* Bluetooth (confirmed stable MAC),
   degrades gracefully to "no match, treat as new" for clones/models with
   empty `uniq` (the current behavior), and needs zero new processes —
   `controller_monitor.sh` already parses this file format.
2. **The real fix for "reconnect resumes the running instance" (issue #38)
   is the persistent-uinput-proxy pattern** — not a novel design, it's what
   Steam Input, InputPlumber, MoltenGamepad, WiimoteGlue, and
   `nexus_gamepad_uinput` all independently converged on. Bind the proxy
   device into the sandbox instead of the raw node; a small host-side helper
   re-attaches the real controller's events to the slot's proxy on reconnect,
   matched by `uniq` when present and falling back to vendor:product +
   connection-order otherwise. This is sizable (a uinput lifecycle + an
   event-forwarding helper) — correctly scoped to v2/v3 in #38, not v1.1.
3. **Don't rely on SDL GUID for identity** — it's model-level, not per-unit,
   confirmed by reading the SDL source. Two identical pads are indistinguishable
   to Controlify's SDL layer regardless of what we do upstream.
4. **Don't build a udev by-id/serial matching layer as the primary mechanism**
   — the `noserial` collision case is real and well-documented; it only helps
   for pads that do expose a genuine serial/uniq, which is exactly the same
   data source as option 1, with more infrastructure (a rules file, `udevadm
   trigger`) for no extra reliability over reading `/proc/bus/input/devices`
   directly, which the codebase already does.

## Sources (see individual sub-agent reports for full citation lists)

SDL: `libsdl-org/SDL` `src/joystick/linux/SDL_sysjoystick.c`,
`src/joystick/SDL_joystick.c`, `src/core/linux/SDL_udev.c`. InputPlumber:
`ShadowBlip/InputPlumber` `src/input/manager.rs`,
`rootfs/usr/share/inputplumber/schema/composite_device_v1.json`, issue #570.
uinput prior art: `jgeumlek/MoltenGamepad`, `jgeumlek/WiimoteGlue`,
`Phasip/nexus_gamepad_uinput` READMEs. HID identity: kernel
`drivers/hid/hid-sony.c` (mainline), `Documentation/hid/hid-transport.rst`,
`Kyuunex/hid-sony-clone-fix-dkms`. udev naming: `systemd/systemd`
`rules.d/60-persistent-input.rules`, `robfisc/controller-udev-rules`,
`phantom-voltage/xboxdrv-udev-rules`.
