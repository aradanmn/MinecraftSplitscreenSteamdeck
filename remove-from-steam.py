#!/usr/bin/env python3
# --- Minecraft Splitscreen Steam Shortcut Remover ---
# The inverse of add-to-steam.py (#122): takes our entry back out of Steam's
# shortcuts.vdf and deletes the SteamGridDB artwork it downloaded, so a full
# uninstall leaves no trace in the Steam library.
#
# WHY A REAL PARSER AND NOT A REGEX
# ---------------------------------
# shortcuts.vdf holds EVERY non-Steam shortcut the user has — emulators, other
# launchers, work tools. A byte-splice that guesses wrong does not fail loudly,
# it silently corrupts the file and the user loses all of them. So this script:
#
#   1. parses the binary VDF into a typed tree,
#   2. re-serializes the UNMODIFIED tree and requires it to reproduce the
#      original bytes exactly — if it does not, we do not understand this
#      file and refuse to write it (fail-safe; PRINCIPLES #5),
#   3. writes a timestamped backup before touching anything,
#   4. removes only entries that are provably ours.
#
# Steam caches shortcuts.vdf in memory and rewrites it on exit, so an edit made
# while Steam is running is silently reverted. We detect that and refuse rather
# than reporting a success that will evaporate. (Never restart Steam for the
# user — a remote `steam -shutdown` has wedged Game Mode before.)
#
# Usage:
#   remove-from-steam.py [--dry-run] [--force] [--target-dir DIR]
#     --dry-run     report what would be removed; write nothing
#     --force       proceed even if Steam appears to be running
#     --target-dir  install root, to match entries whose exe lives under it
#
# Exit: 0 removed (or nothing to remove), 1 error, 2 refused (Steam running).

import os
import re
import struct
import sys
import shutil
import time

APPNAME = "Minecraft Splitscreen"   # PAIRED with add-to-steam.py's APPNAME
LAUNCHER_BASENAME = "minecraftSplitscreen.sh"

# Node types in the binary VDF dialect Steam uses for shortcuts.
T_MAP = 0x00
T_STR = 0x01
T_INT = 0x02
T_END = 0x08


class VdfError(Exception):
    """The file is not in the shape we know how to edit."""


# --- parse / serialize -------------------------------------------------------

def _read_cstr(data, i):
    """Read a NUL-terminated byte string starting at i -> (bytes, next_index)."""
    end = data.index(b"\x00", i)
    return data[i:end], end + 1


def parse_map(data, i):
    """
    Parse the body of a map (the caller has consumed its key) starting at i.

    Returns (entries, next_index) where entries is a list of
    (type, key, value) triples — a LIST, not a dict, because order is
    significant on write and duplicate keys are not our business to collapse.
    """
    entries = []
    while True:
        if i >= len(data):
            raise VdfError("unexpected end of file inside a map")
        t = data[i]
        i += 1
        if t == T_END:
            return entries, i
        key, i = _read_cstr(data, i)
        if t == T_MAP:
            val, i = parse_map(data, i)
        elif t == T_STR:
            val, i = _read_cstr(data, i)
        elif t == T_INT:
            val = struct.unpack("<I", data[i:i + 4])[0]
            i += 4
        else:
            raise VdfError(f"unknown node type 0x{t:02x} at offset {i - 1}")
        entries.append((t, key, val))


def serialize_map(entries):
    """Inverse of parse_map: entries -> bytes, WITHOUT the trailing T_END."""
    out = b""
    for t, key, val in entries:
        out += bytes([t]) + key + b"\x00"
        if t == T_MAP:
            out += serialize_map(val) + bytes([T_END])
        elif t == T_STR:
            out += val + b"\x00"
        elif t == T_INT:
            out += struct.pack("<I", val)
        else:
            raise VdfError(f"cannot serialize node type 0x{t:02x}")
    return out


def parse_shortcuts(data):
    """
    Parse a whole shortcuts.vdf.

    Returns (root_entries, trailer) — trailer is whatever bytes follow the
    root map's terminator, preserved verbatim so a round trip is exact.
    """
    if not data:
        raise VdfError("empty file")
    if data[0] != T_MAP:
        raise VdfError("file does not start with a map node")
    key, i = _read_cstr(data, 1)
    if key != b"shortcuts":
        raise VdfError(f"root key is {key!r}, expected b'shortcuts'")
    body, i = parse_map(data, i)
    return [(T_MAP, key, body)], data[i:]


def serialize_shortcuts(root_entries, trailer):
    return serialize_map(root_entries) + trailer


# --- identifying OUR entries -------------------------------------------------

def _field(entry_body, name):
    """Fetch a field's value from one shortcut entry, case-insensitively."""
    want = name.lower().encode()
    for t, key, val in entry_body:
        if key.lower() == want:
            return val
    return None


def is_ours(entry_body, target_dir):
    """
    Decide whether one shortcut entry belongs to this project.

    Deliberately conservative — matching only on the launcher script path or
    our exact app name. A shortcut the user made themselves that merely
    mentions Minecraft must survive.
    """
    appname = _field(entry_body, "appname") or b""
    exe = _field(entry_body, "exe") or b""
    exe_s = exe.decode("utf-8", "replace").strip('"')
    if LAUNCHER_BASENAME in exe_s:
        return True
    if appname.decode("utf-8", "replace") == APPNAME:
        return True
    if target_dir and exe_s.startswith(target_dir.rstrip("/") + "/"):
        return True
    return False


# --- Steam liveness ----------------------------------------------------------

def steam_is_running():
    """
    True if a Steam client process appears to be alive.

    Reads /proc directly rather than shelling out to pgrep: pgrep -f would
    match this very script's own command line, and the repo has been bitten by
    exactly that before.
    """
    try:
        pids = [d for d in os.listdir("/proc") if d.isdigit()]
    except OSError:
        return False
    for pid in pids:
        try:
            with open(f"/proc/{pid}/comm", "rb") as f:
                comm = f.read().strip()
        except OSError:
            continue
        if comm in (b"steam", b"steamwebhelper"):
            return True
    return False


# --- main --------------------------------------------------------------------

def find_shortcuts_files():
    """Every userdata/<id>/config/shortcuts.vdf on this machine."""
    userdata = os.path.expanduser("~/.steam/steam/userdata")
    found = []
    if not os.path.isdir(userdata):
        return found
    for d in sorted(os.listdir(userdata)):
        if not d.isdigit():
            continue
        p = os.path.join(userdata, d, "config", "shortcuts.vdf")
        if os.path.exists(p):
            found.append(p)
    return found


def remove_grid_art(config_dir, appid, dry_run):
    """Delete the SteamGridDB files add-to-steam.py downloaded for this appid."""
    grid = os.path.join(config_dir, "grid")
    if not os.path.isdir(grid):
        return 0
    n = 0
    pattern = re.compile(rf"^{appid}(p|_hero|_logo|_icon)?\.(png|jpg|ico)$")
    for name in sorted(os.listdir(grid)):
        if pattern.match(name):
            path = os.path.join(grid, name)
            if dry_run:
                print(f"[dry-run] would remove artwork: {path}")
            else:
                try:
                    os.remove(path)
                    print(f"removed artwork: {path}")
                except OSError as e:
                    print(f"WARNING: could not remove {path}: {e}")
                    continue
            n += 1
    return n


def process(path, target_dir, dry_run):
    """Remove our entries from one shortcuts.vdf. Returns the count removed."""
    with open(path, "rb") as f:
        original = f.read()

    root, trailer = parse_shortcuts(original)

    # Round-trip guard: if re-serializing what we just parsed does not
    # reproduce the input byte for byte, our understanding of the format is
    # incomplete and writing would risk the user's other shortcuts.
    if serialize_shortcuts(root, trailer) != original:
        raise VdfError(
            "round-trip check failed — refusing to modify this file. "
            "Remove the shortcut manually from Steam."
        )

    shortcuts = root[0][2]
    keep, drop = [], []
    for node in shortcuts:
        t, key, body = node
        if t == T_MAP and is_ours(body, target_dir):
            drop.append(node)
        else:
            keep.append(node)

    if not drop:
        print(f"no Minecraft Splitscreen shortcut in {path}")
        return 0

    config_dir = os.path.dirname(path)
    for _, key, body in drop:
        appname = (_field(body, "appname") or b"?").decode("utf-8", "replace")
        appid = _field(body, "appid")
        print(f"{'[dry-run] would remove' if dry_run else 'removing'} "
              f"shortcut: {appname} (appid {appid})")
        if appid is not None:
            remove_grid_art(config_dir, appid, dry_run)

    # Steam indexes entries by their key, "0", "1", "2"… Leaving a hole would
    # be malformed, so renumber what remains.
    renumbered = [(T_MAP, str(n).encode(), body)
                  for n, (_, _, body) in enumerate(keep)]
    new_root = [(T_MAP, b"shortcuts", renumbered)]
    new_data = serialize_shortcuts(new_root, trailer)

    if dry_run:
        print(f"[dry-run] would rewrite {path} "
              f"({len(drop)} removed, {len(keep)} kept)")
        return len(drop)

    backup = f"{path}.mcss-backup-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    print(f"backed up: {backup}")
    with open(path, "wb") as f:
        f.write(new_data)
    print(f"rewrote {path} ({len(drop)} removed, {len(keep)} kept)")
    return len(drop)


def main(argv):
    dry_run = "--dry-run" in argv
    force = "--force" in argv
    target_dir = ""
    if "--target-dir" in argv:
        i = argv.index("--target-dir")
        if i + 1 >= len(argv):
            print("--target-dir requires a directory", file=sys.stderr)
            return 1
        target_dir = argv[i + 1]

    files = find_shortcuts_files()
    if not files:
        print("no Steam shortcuts.vdf found — nothing to do")
        return 0

    if steam_is_running() and not dry_run and not force:
        print("REFUSED: Steam is running. It keeps shortcuts.vdf in memory and "
              "rewrites it on exit, so this edit would be silently reverted.",
              file=sys.stderr)
        print("         Close Steam, then re-run. (Do not use `steam "
              "-shutdown` over SSH — it has wedged Game Mode.)", file=sys.stderr)
        print("         Use --force to override.", file=sys.stderr)
        return 2

    total = 0
    for path in files:
        try:
            total += process(path, target_dir, dry_run)
        except (VdfError, OSError) as e:
            print(f"ERROR on {path}: {e}", file=sys.stderr)
            return 1
    print(f"done — {total} shortcut(s) "
          f"{'would be ' if dry_run else ''}removed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
