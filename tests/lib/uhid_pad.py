#!/usr/bin/env python3
# =============================================================================
# uhid_pad.py — create and drive a virtual gamepad through /dev/uhid
# =============================================================================
# TEST TOOLING (issue #136 / build plan #157). Not part of the runtime; nothing
# under modules/ imports this.
#
# WHY uhid AND NOT uinput (docs/RESEARCH-136-VIRTUAL-PAD-RIG.md):
#   - uinput cannot set `uniq`. slot_manager keys reconnect identity on it and
#     never matches an empty key, so a uinput pad could never take the RESUME
#     path that v1.2 ships.
#   - Every uinput device lives at /devices/virtual/input/inputN, which collapses
#     to one parent key under _list_raw_external_pads' step-6 dedup.
#   uhid takes a caller-supplied uniq (struct uhid_create2_req.uniq[64], which
#   HID core copies to input_dev->uniq in hidinput_allocate) and gives each
#   device its own parent — the same path BlueZ uses for real Bluetooth pads.
#
# PURE vs I/O (PRINCIPLES: pure functions at the edges). Everything that
# computes bytes — the report descriptor, report encoding, the spec parser — is
# a module-level pure function with no device access, exercised by
# tests/test_uhid_pad.sh in CI. Only UhidPad touches /dev/uhid.
#
# USAGE
#   Pure (no hardware, no root):
#     uhid_pad.py --emit-descriptor
#     uhid_pad.py --encode-report BTN_SOUTH=1,LX=200
#     uhid_pad.py --self-test
#
#   Device (needs /dev/uhid, usually root):
#     uhid_pad.py create --uniq aa:bb:cc:00:00:01 --name "MCSS Test Pad 1" \
#                        --vendor 0x054c --product 0x0001
#     Holds the device open until stdin closes or `destroy` is read — the
#     process lifetime IS the pad lifetime, so whoever started it can end it by
#     killing exactly that PID (PRINCIPLES #7).
#
#   stdin command stream (one per line):
#     press <BTN> | release <BTN> | hold <BTN> <ms> | axis <NAME> <0-255>
#     hat <DIR> | neutral | destroy
#
#   Full Xbox/8BitDo-style surface (#70 2P+ session — a bare-minimum pad
#   couldn't reach any control that isn't bound to a face button/stick):
#     Buttons — 4 face (SOUTH/EAST/WEST/NORTH), 2 bumpers (TL/TR), 2 digital
#       triggers (TL2/TR2), SELECT/START, MODE (Guide/Home), 2 stick clicks
#       (THUMBL/THUMBR, i.e. L3/R3). BTN_C/BTN_Z (3, 6) are unused positional
#       artifacts of the sequential Button-N mapping below — real hardware
#       leaves them unpressed too.
#     Sticks — LX/LY (left), RX/RY (right), 0-255, neutral 128.
#     Triggers — LT/RT analog axes, 0-255, neutral 0 (released, NOT centred —
#       a trigger's rest state is "not pulled", unlike a stick's centre).
#     D-pad — one HAT switch (`hat <DIR>`), not 4 separate buttons: hid-input
#       converts a single 0-7 Hat Switch usage into ABS_HAT0X/ABS_HAT0Y
#       automatically (ships as one field, not on the BUTTONS ladder).
#
# Version history:
#   v1.0 2026-07-29  #136 PR-0: initial primitive + feasibility probe support.
#   v1.1 2026-08-08  #70: full controller surface — D-pad (HAT), analog
#                    LT/RT, MODE/Guide button. Prior 6-byte/12-button/4-axis
#                    pad had no way to reach anything not bound to a face
#                    button or stick (chat, menus, guide-button shortcuts).
#   v1.2 2026-08-08  #70: add THUMBL/THUMBR (L3/R3 stick clicks) — 13-button
#                    pad still had no way to reach a stick-click-bound action.
# =============================================================================

import argparse
import os
import struct
import sys
import time

# --- uhid uapi constants (include/uapi/linux/uhid.h) -------------------------

UHID_DESTROY = 1
UHID_START = 2
UHID_STOP = 3
UHID_OPEN = 4
UHID_CLOSE = 5
UHID_OUTPUT = 6
UHID_CREATE2 = 11
UHID_INPUT2 = 12

HID_MAX_DESCRIPTOR_SIZE = 4096
UHID_DATA_MAX = 4096

BUS_BLUETOOTH = 0x05

# struct uhid_create2_req — packed, so '<' (no alignment padding) is exact:
#   __u8 name[128]; __u8 phys[64]; __u8 uniq[64]; __u16 rd_size; __u16 bus;
#   __u32 vendor; __u32 product; __u32 version; __u32 country;
#   __u8 rd_data[HID_MAX_DESCRIPTOR_SIZE];
_CREATE2_FMT = "<128s64s64sHHIIII%ds" % HID_MAX_DESCRIPTOR_SIZE

# struct uhid_event { __u32 type; union {...} u; } — create2 is the largest
# union member, so this is sizeof(struct uhid_event).
UHID_EVENT_SIZE = 4 + struct.calcsize(_CREATE2_FMT)

# --- report layout -----------------------------------------------------------
#
# 9 bytes: [buttons 1-8][buttons 9-15 + 1 pad][hat + 4 pad][LX][LY][RX][RY]
#          [LT][RT]
#
# Button index N maps to BTN_GAMEPAD + (N-1) because the application collection
# is Usage(Gamepad) — hid-input.c's HID_UP_BUTTON case. Index 1 is therefore
# BTN_SOUTH (0x130), which is exactly the bit controller_monitor.sh's
# _has_gamepad_buttons gates on. Index 13 lands on BTN_MODE (0x13c) — the
# Guide/Home button real pads use for a menu shortcut. Indices 14/15 land on
# BTN_THUMBL/BTN_THUMBR (0x13d/0x13e) — the left/right stick-click buttons.
#
# The D-pad is ONE HAT SWITCH usage (0x39), not 4 buttons: hid-input.c
# recognizes a Generic-Desktop Hat Switch with a 0-7 logical range (+ the
# Null State input flag for "no direction") and synthesizes ABS_HAT0X/
# ABS_HAT0Y from it directly — the kernel does the direction math, we just
# report 0-7 (clockwise from Up) or 8 (released, outside the valid range so
# Null State maps it to centred).

REPORT_SIZE = 9
BUTTON_COUNT = 15
AXIS_NEUTRAL = 128

BUTTONS = {
    "BTN_SOUTH": 1, "BTN_EAST": 2, "BTN_C": 3, "BTN_NORTH": 4,
    "BTN_WEST": 5, "BTN_Z": 6, "BTN_TL": 7, "BTN_TR": 8,
    "BTN_TL2": 9, "BTN_TR2": 10, "BTN_SELECT": 11, "BTN_START": 12,
    "BTN_MODE": 13, "BTN_THUMBL": 14, "BTN_THUMBR": 15,
}

# Declaration order matters — it is the report's byte order (byte3..byte8).
AXIS_ORDER = ("LX", "LY", "RX", "RY", "LT", "RT")
AXES = {name: i for i, name in enumerate(AXIS_ORDER)}
# Sticks rest at centre (128); triggers rest at 0 — "not pulled", not "centred".
AXIS_DEFAULT = {"LX": AXIS_NEUTRAL, "LY": AXIS_NEUTRAL,
                 "RX": AXIS_NEUTRAL, "RY": AXIS_NEUTRAL,
                 "LT": 0, "RT": 0}

# Hat Switch: 0-7 clockwise from Up, both plain compass names and N/E/S/W-style
# aliases (this project's own bearing convention, tests/benchmark/RUNBOOK.md).
# 8 = released/centred (outside the 0-7 logical range → Null State).
HAT_RELEASED = 8
HAT_DIRECTIONS = {
    "UP": 0, "N": 0,
    "UP_RIGHT": 1, "NE": 1,
    "RIGHT": 2, "E": 2,
    "DOWN_RIGHT": 3, "SE": 3,
    "DOWN": 4, "S": 4,
    "DOWN_LEFT": 5, "SW": 5,
    "LEFT": 6, "W": 6,
    "UP_LEFT": 7, "NW": 7,
    "RELEASED": HAT_RELEASED, "NEUTRAL": HAT_RELEASED, "CENTER": HAT_RELEASED,
}


def normalize_button(name):
    """'south' / 'BTN_SOUTH' -> canonical key. Raises ValueError if unknown."""
    key = name.strip().upper()
    if not key.startswith("BTN_"):
        key = "BTN_" + key
    if key not in BUTTONS:
        raise ValueError("unknown button %r (known: %s)"
                         % (name, ", ".join(sorted(BUTTONS))))
    return key


def normalize_axis(name):
    """'lx' / 'X' / 'Z' -> canonical axis key. Raises ValueError if unknown.

    Accepts the raw HID usage names (X, Y, Z, RZ) as aliases for the stick/
    trigger names actually used on the wire (LX, LY, LT, RT) — RX/RY already
    match directly, no alias needed.
    """
    key = name.strip().upper()
    key = {"X": "LX", "Y": "LY", "Z": "LT", "RZ": "RT"}.get(key, key)
    if key not in AXES:
        raise ValueError("unknown axis %r (known: %s)"
                         % (name, ", ".join(sorted(AXES))))
    return key


def normalize_hat(value):
    """direction name / compass alias / 0-8 int -> canonical 0-8 int. Pure."""
    if isinstance(value, int):
        v = value
    else:
        s = str(value).strip()
        if s.lstrip("-").isdigit():
            v = int(s)
        else:
            key = s.upper().replace("-", "_")
            if key not in HAT_DIRECTIONS:
                raise ValueError(
                    "unknown hat direction %r (known: %s)"
                    % (value, ", ".join(sorted(HAT_DIRECTIONS))))
            v = HAT_DIRECTIONS[key]
    if not 0 <= v <= HAT_RELEASED:
        raise ValueError("hat value out of range 0-%d: %r" % (HAT_RELEASED, value))
    return v


def build_report_descriptor():
    """The HID report descriptor for our generic gamepad. Pure.

    Usage(Gamepad) at the application collection is load-bearing: it is what
    makes hid-input map button 1 to BTN_SOUTH rather than BTN_TRIGGER, and
    BTN_SOUTH is what _has_gamepad_buttons looks for. Usage(Joystick) would
    also pass that gate (BTN_JOYSTICK is accepted too) but would present as a
    joystick to Controlify.
    """
    return bytes([
        0x05, 0x01,        # Usage Page (Generic Desktop)
        0x09, 0x05,        # Usage (Gamepad)
        0xA1, 0x01,        # Collection (Application)
        0xA1, 0x00,        #   Collection (Physical)
        0x05, 0x09,        #     Usage Page (Button)
        0x19, 0x01,        #     Usage Minimum (Button 1)
        0x29, BUTTON_COUNT,  #   Usage Maximum (Button 15)
        0x15, 0x00,        #     Logical Minimum (0)
        0x25, 0x01,        #     Logical Maximum (1)
        0x75, 0x01,        #     Report Size (1)
        0x95, BUTTON_COUNT,  #   Report Count (15)
        0x81, 0x02,        #     Input (Data, Variable, Absolute)
        0x75, 0x01,        #     Report Size (1)       -- pad to a byte boundary
        0x95, 0x01,        #     Report Count (1)
        0x81, 0x03,        #     Input (Constant, Variable, Absolute)
        0x05, 0x01,        #     Usage Page (Generic Desktop)
        0x09, 0x39,        #     Usage (Hat Switch)
        0x15, 0x00,        #     Logical Minimum (0)
        0x25, 0x07,        #     Logical Maximum (7)
        0x75, 0x04,        #     Report Size (4)
        0x95, 0x01,        #     Report Count (1)
        0x81, 0x42,        #     Input (Data, Variable, Absolute, Null State)
        0x75, 0x04,        #     Report Size (4)       -- pad the hat nibble to a byte
        0x95, 0x01,        #     Report Count (1)
        0x81, 0x03,        #     Input (Constant, Variable, Absolute)
        0x05, 0x01,        #     Usage Page (Generic Desktop)
        0x09, 0x30,        #     Usage (X)   -- LX
        0x09, 0x31,        #     Usage (Y)   -- LY
        0x09, 0x33,        #     Usage (Rx)  -- RX
        0x09, 0x34,        #     Usage (Ry)  -- RY
        0x09, 0x32,        #     Usage (Z)   -- LT
        0x09, 0x35,        #     Usage (Rz)  -- RT
        0x15, 0x00,        #     Logical Minimum (0)
        0x26, 0xFF, 0x00,  #     Logical Maximum (255)
        0x75, 0x08,        #     Report Size (8)
        0x95, 0x06,        #     Report Count (6)
        0x81, 0x02,        #     Input (Data, Variable, Absolute)
        0xC0,              #   End Collection
        0xC0,              # End Collection
    ])


def encode_report(pressed=(), axes=None, hat="RELEASED"):
    """Pack a 9-byte input report. Pure.

    pressed — iterable of canonical button keys currently held.
    axes    — {canonical axis key: 0-255}; anything absent sits at its
              per-axis default (128 for sticks, 0 for triggers).
    hat     — a direction name/alias or 0-8 int; default RELEASED (8).
    """
    axes = axes or {}
    bits = 0
    for name in pressed:
        bits |= 1 << (BUTTONS[normalize_button(name)] - 1)
    values = [AXIS_DEFAULT[name] for name in AXIS_ORDER]
    for name, value in axes.items():
        idx = AXES[normalize_axis(name)]
        if not 0 <= int(value) <= 255:
            raise ValueError("axis %s out of range: %r" % (name, value))
        values[idx] = int(value)
    hat_value = normalize_hat(hat)
    return struct.pack("<BBB%dB" % len(AXIS_ORDER),
                        bits & 0xFF, (bits >> 8) & 0xFF, hat_value, *values)


def parse_report_spec(spec):
    """'BTN_SOUTH=1,LX=200,HAT=NE' -> (pressed set, axes dict, hat). Pure.

    Buttons take 0/1; axes take 0-255; HAT takes a direction name/alias or a
    0-8 int. Raises ValueError on anything else so a typo fails loudly
    instead of silently encoding a neutral report.
    """
    pressed, axes, hat = set(), {}, "RELEASED"
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            raise ValueError("expected NAME=VALUE, got %r" % item)
        name, _, raw = item.partition("=")
        upper = name.strip().upper()
        if upper == "HAT":
            hat = normalize_hat(raw.strip())
            continue
        try:
            value = int(raw, 0)
        except ValueError:
            raise ValueError("non-numeric value in %r" % item)
        if upper in AXES or upper in ("X", "Y", "Z", "RZ"):
            axes[normalize_axis(upper)] = value
        else:
            key = normalize_button(upper)
            if value not in (0, 1):
                raise ValueError("button %s takes 0 or 1, got %r" % (key, value))
            if value:
                pressed.add(key)
    return pressed, axes, hat


def build_create2_event(name, uniq, vendor, product, phys="", version=0,
                        country=0, bus=BUS_BLUETOOTH):
    """Pack a UHID_CREATE2 event. Pure — returns the bytes, writes nothing.

    Bus defaults to BLUETOOTH so the device presents the way a real BT pad
    does; nothing in our enumeration keys on bustype, but the fidelity is free.
    """
    rd = build_report_descriptor()
    if len(rd) > HID_MAX_DESCRIPTOR_SIZE:
        raise ValueError("report descriptor too large: %d" % len(rd))
    payload = struct.pack(
        _CREATE2_FMT,
        name.encode()[:127], phys.encode()[:63], uniq.encode()[:63],
        len(rd), bus, vendor, product, version, country,
        rd + b"\0" * (HID_MAX_DESCRIPTOR_SIZE - len(rd)),
    )
    return _pad_event(struct.pack("<I", UHID_CREATE2) + payload)


def build_input2_event(report):
    """Pack a UHID_INPUT2 event carrying `report`. Pure."""
    if len(report) > UHID_DATA_MAX:
        raise ValueError("report too large: %d" % len(report))
    body = struct.pack("<IH", UHID_INPUT2, len(report)) + report
    return _pad_event(body)


def _pad_event(body):
    """Zero-pad to sizeof(struct uhid_event).

    The kernel zero-fills a short write, so this is belt-and-braces — but an
    exact-size write is what every other uhid client does, and it means a
    truncated struct shows up here as an assertion rather than as a device
    that silently comes up wrong.
    """
    if len(body) > UHID_EVENT_SIZE:
        raise ValueError("event larger than sizeof(uhid_event): %d" % len(body))
    return body + b"\0" * (UHID_EVENT_SIZE - len(body))


# --- device side (the only part that touches /dev/uhid) ----------------------

class UhidPad(object):
    """A live uhid device. Open it, and it exists until close()."""

    def __init__(self, name, uniq, vendor, product, path="/dev/uhid"):
        self.name, self.uniq = name, uniq
        self.vendor, self.product = vendor, product
        self.path = path
        self.fd = None
        self._pressed = set()
        self._axes = {}
        self._hat = HAT_RELEASED

    def create(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_NONBLOCK)
        os.write(self.fd, build_create2_event(
            self.name, self.uniq, self.vendor, self.product))
        self.send()          # an initial neutral report
        return self

    def send(self):
        os.write(self.fd, build_input2_event(
            encode_report(self._pressed, self._axes, self._hat)))

    def press(self, button):
        self._pressed.add(normalize_button(button))
        self.send()

    def release(self, button):
        self._pressed.discard(normalize_button(button))
        self.send()

    def axis(self, name, value):
        self._axes[normalize_axis(name)] = int(value)
        self.send()

    def hat(self, direction):
        self._hat = normalize_hat(direction)
        self.send()

    def neutral(self):
        self._pressed.clear()
        self._axes.clear()
        self._hat = HAT_RELEASED
        self.send()

    def drain(self):
        """Read and discard queued kernel events (UHID_START/OPEN/…).

        Non-blocking: the fd is O_NONBLOCK, so this returns as soon as the
        queue is empty. We don't act on these events — we only keep the queue
        from filling.
        """
        while True:
            try:
                if not os.read(self.fd, UHID_EVENT_SIZE):
                    return
            except (BlockingIOError, OSError):
                return

    def close(self):
        if self.fd is None:
            return
        try:
            os.write(self.fd, _pad_event(struct.pack("<I", UHID_DESTROY)))
        except OSError:
            pass          # fail open: closing the fd destroys it regardless
        os.close(self.fd)
        self.fd = None


def _run_command_loop(pad):
    """Read commands from stdin until EOF or `destroy`. Returns an exit code."""
    for line in sys.stdin:
        parts = line.split()
        if not parts:
            continue
        cmd, args = parts[0].lower(), parts[1:]
        try:
            if cmd in ("destroy", "quit", "exit"):
                break
            elif cmd == "press":
                pad.press(args[0])
            elif cmd == "release":
                pad.release(args[0])
            elif cmd == "hold":
                pad.press(args[0])
                time.sleep(int(args[1]) / 1000.0)
                pad.release(args[0])
            elif cmd == "axis":
                pad.axis(args[0], args[1])
            elif cmd == "hat":
                pad.hat(args[0])
            elif cmd == "neutral":
                pad.neutral()
            else:
                print("unknown command: %s" % cmd, file=sys.stderr)
                continue
        except (IndexError, ValueError) as exc:
            print("bad command %r: %s" % (line.strip(), exc), file=sys.stderr)
            continue
        pad.drain()
        print("ok %s" % cmd, flush=True)
    return 0


def _self_test():
    """Pure assertions that must hold identically in CI and on the Deck.

    Printed as `name=value` lines so the bash suite can assert them without
    reimplementing any of the packing.
    """
    desc = build_report_descriptor()
    neutral = encode_report()
    south = encode_report(["BTN_SOUTH"])
    start = encode_report(["BTN_START"])
    mode = encode_report(["BTN_MODE"])
    thumbs = encode_report(["BTN_THUMBL", "BTN_THUMBR"])
    both = encode_report(["BTN_SOUTH", "BTN_START"], {"LX": 200})
    hat_up = encode_report(hat="UP")
    trigger = encode_report(axes={"LT": 255, "RT": 64})
    pressed, axes, _spec_hat = parse_report_spec("BTN_SOUTH=1,LX=200")
    _hat_pressed, _hat_axes, spec_hat = parse_report_spec("HAT=NE")
    lines = [
        ("event_size", UHID_EVENT_SIZE),
        ("descriptor_len", len(desc)),
        ("descriptor_hex", desc.hex()),
        ("report_len", len(neutral)),
        ("report_neutral", neutral.hex()),
        ("report_south", south.hex()),
        ("report_start", start.hex()),
        ("report_mode", mode.hex()),
        ("report_thumbs", thumbs.hex()),
        ("report_south_start_lx200", both.hex()),
        ("report_hat_up", hat_up.hex()),
        ("report_trigger", trigger.hex()),
        ("create2_event_size", len(build_create2_event(
            "MCSS Test Pad", "aa:bb:cc:00:00:01", 0x054C, 0x0001))),
        ("input2_event_size", len(build_input2_event(neutral))),
        ("spec_pressed", ",".join(sorted(pressed))),
        ("spec_axes", ",".join("%s=%d" % kv for kv in sorted(axes.items()))),
        ("spec_hat", str(spec_hat)),
    ]
    for key, value in lines:
        print("%s=%s" % (key, value))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="create and drive a virtual gamepad via /dev/uhid")
    parser.add_argument("--emit-descriptor", action="store_true",
                        help="print the report descriptor as hex and exit")
    parser.add_argument("--encode-report", metavar="SPEC",
                        help="print one encoded report as hex and exit")
    parser.add_argument("--self-test", action="store_true",
                        help="print pure-computation values for CI/Deck compare")
    parser.add_argument("mode", nargs="?", choices=["create"],
                        help="create a device and read commands on stdin")
    parser.add_argument("--name", default="MCSS Test Pad")
    parser.add_argument("--uniq", default="aa:bb:cc:00:00:01")
    parser.add_argument("--vendor", type=lambda v: int(v, 0), default=0x054C)
    parser.add_argument("--product", type=lambda v: int(v, 0), default=0x0001)
    parser.add_argument("--device", default="/dev/uhid")
    args = parser.parse_args(argv)

    if args.emit_descriptor:
        print(build_report_descriptor().hex())
        return 0
    if args.encode_report:
        pressed, axes, hat = parse_report_spec(args.encode_report)
        print(encode_report(pressed, axes, hat).hex())
        return 0
    if args.self_test:
        return _self_test()
    if args.mode != "create":
        parser.print_help(sys.stderr)
        return 2

    pad = UhidPad(args.name, args.uniq, args.vendor, args.product, args.device)
    try:
        pad.create()
    except PermissionError:
        print("cannot open %s (permission denied) — try sudo, or add a udev "
              "rule" % args.device, file=sys.stderr)
        return 13
    except FileNotFoundError:
        print("%s not present — is the uhid module loaded?" % args.device,
              file=sys.stderr)
        return 14
    # Announce readiness on stdout so a caller can wait on a line rather than
    # on a fixed sleep (PRINCIPLES #6 — bounded, observable waits).
    print("created uniq=%s name=%s" % (args.uniq, args.name), flush=True)
    try:
        return _run_command_loop(pad)
    finally:
        pad.close()


if __name__ == "__main__":
    sys.exit(main())
