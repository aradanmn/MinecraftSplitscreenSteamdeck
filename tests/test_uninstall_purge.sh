#!/bin/bash
set -uo pipefail

# =============================================================================
# Test Suite: uninstall --purge + remove-from-steam.py (#122)
# =============================================================================
# This is the one code path in the project whose JOB is to delete the user's
# data, and it now also rewrites shortcuts.vdf — a file holding every non-Steam
# shortcut the user owns, ours and other people's alike. The cost of a mistake
# is asymmetric and unrecoverable, so the properties pinned here are mostly
# about what must SURVIVE, not what gets removed.
#
# Every case runs against a throwaway $HOME. Nothing touches the real one, no
# podman is required, and the only process spawned is a renamed `sleep` used to
# exercise the Steam-is-running guard — killed by tracked PID, never by name
# (PRINCIPLES #7).
#
# Run: bash tests/test_uninstall_purge.sh
# =============================================================================

readonly TEST_TOTAL=22

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly UNINSTALL="$REPO_ROOT/uninstall-minecraft-splitscreen.sh"
readonly REMOVER="$REPO_ROOT/remove-from-steam.py"

TESTS_PASSED=0
TESTS_FAILED=0
TMPDIR_TEST=""

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

_expect() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then _pass "$name"
    else _fail "$name" "expected '$expected', got '$actual'"; fi
}

_expect_exists() {
    local name="$1" path="$2"
    if [[ -e "$path" ]]; then _pass "$name"
    else _fail "$name" "missing: $path"; fi
}

_expect_gone() {
    local name="$1" path="$2"
    if [[ ! -e "$path" ]]; then _pass "$name"
    else _fail "$name" "still present: $path"; fi
}

_setup() { TMPDIR_TEST="$(mktemp -d)"; }
_teardown() { [[ -n "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"; TMPDIR_TEST=""; }
trap _teardown EXIT

# _fake_install: Build a throwaway $HOME holding a plausible install.
# Outputs: stdout — the fake HOME path
_fake_install() {
    local h="$TMPDIR_TEST/home"
    mkdir -p "$h/.local/share/PolyMC/instances/latestUpdate-1" \
             "$h/.local/share/PolyMC/meta/org.lwjgl3" \
             "$h/.config/minecraft-splitscreen" \
             "$h/Desktop" "$h/.local/share/applications"
    echo "secret" > "$h/.config/minecraft-splitscreen/curseforge-api-key"
    echo "world"  > "$h/.local/share/PolyMC/instances/latestUpdate-1/world.dat"
    echo "meta"   > "$h/.local/share/PolyMC/meta/org.lwjgl3/index.json"
    : > "$h/Desktop/MinecraftSplitscreen.desktop"
    : > "$h/.local/share/PolyMC/minecraftSplitscreen.sh"
    echo "$h"
}

# _fake_steam: Write a shortcuts.vdf holding one of ours between two foreign
# entries, plus grid artwork for ours and for a foreign appid.
# Inputs: $1 — fake HOME
# Outputs: stdout — "<our_appid> <config_dir>"
_fake_steam() {
    local h="$1"
    local cfg="$h/.steam/steam/userdata/12345678/config"
    mkdir -p "$cfg/grid"
    local appid
    appid="$(python3 - "$cfg/shortcuts.vdf" <<'PY'
import struct, sys, zlib
def entry(index, appid, appname, exe, startdir):
    x00=b'\x00'; x01=b'\x01'; x02=b'\x02'; x08=b'\x08'
    b  = x00 + str(index).encode() + x00
    b += x02 + b'appid' + x00 + struct.pack('<I', appid)
    b += x01 + b'appname' + x00 + appname.encode() + x00
    b += x01 + b'exe' + x00 + exe.encode() + x00
    b += x01 + b'StartDir' + x00 + startdir.encode() + x00
    b += x01 + b'LaunchOptions' + x00 + b'launchFromPlasma' + x00
    return b + x08
APP = "Minecraft Splitscreen"
EXE = "/home/deck/.local/share/PolyMC/minecraftSplitscreen.sh"
ours = 0x80000000 | zlib.crc32((APP+EXE).encode()) & 0xFFFFFFFF
data  = b'\x00shortcuts\x00'
data += entry(0, 0x81111111, "RetroArch", "/usr/bin/retroarch", "/usr/bin")
data += entry(1, ours, APP, EXE, "/home/deck/.local/share/PolyMC")
data += entry(2, 0x82222222, "Heroic Games", "/usr/bin/heroic", "/usr/bin")
data += b'\x08\x08'
open(sys.argv[1], "wb").write(data)
print(ours)
PY
)"
    local s
    for s in "" p _hero _logo; do : > "$cfg/grid/${appid}${s}.png"; done
    : > "$cfg/grid/${appid}_icon.ico"
    : > "$cfg/grid/2172748561.png"     # a foreign shortcut's artwork
    echo "$appid $cfg"
}

# _shortcut_names: List the appnames remaining in a shortcuts.vdf, in order.
_shortcut_names() {
    python3 - "$REMOVER" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("r", sys.argv[1])
r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
root, _ = r.parse_shortcuts(open(sys.argv[2], "rb").read())
print(" ".join(f"{k.decode()}:{r._field(b,'appname').decode()}"
                for _, k, b in root[0][2]))
PY
}

# --- T1: flag handling -------------------------------------------------------

test_purge_and_keep_data_conflict() {
    _setup
    local h; h="$(_fake_install)"
    local rc=0
    HOME="$h" bash "$UNINSTALL" --purge --keep-data --yes >/dev/null 2>&1 || rc=$?
    _expect "T1.1 --purge --keep-data is rejected" "$rc" "1"
    _teardown
}

test_conflict_is_order_independent() {
    _setup
    local h; h="$(_fake_install)"
    local rc=0
    HOME="$h" bash "$UNINSTALL" --keep-data --purge --yes >/dev/null 2>&1 || rc=$?
    _expect "T1.2 conflict caught with flags reversed" "$rc" "1"
    _teardown
}

test_conflict_deletes_nothing() {
    # A rejected invocation must abort BEFORE any removal.
    _setup
    local h; h="$(_fake_install)"
    HOME="$h" bash "$UNINSTALL" --purge --keep-data --yes >/dev/null 2>&1
    _expect_exists "T1.3 rejected invocation deletes nothing" \
        "$h/.local/share/PolyMC/instances/latestUpdate-1/world.dat"
    _teardown
}

# --- T2: what --purge removes ------------------------------------------------

test_purge_removes_byok_key() {
    _setup
    local h; h="$(_fake_install)"
    HOME="$h" bash "$UNINSTALL" --purge --yes >/dev/null 2>&1
    _expect_gone "T2.1 --purge removes the BYOK key dir" \
        "$h/.config/minecraft-splitscreen"
    _teardown
}

test_purge_removes_meta_cache() {
    # The meta/ cache goes with the whole TARGET_DIR — #114's stale-metadata
    # crash came from a selective removal leaving it behind.
    _setup
    local h; h="$(_fake_install)"
    HOME="$h" bash "$UNINSTALL" --purge --yes >/dev/null 2>&1
    _expect_gone "T2.2 --purge removes the PolyMC meta/ cache" \
        "$h/.local/share/PolyMC/meta"
    _teardown
}

test_purge_dry_run_removes_nothing() {
    _setup
    local h; h="$(_fake_install)"
    HOME="$h" bash "$UNINSTALL" --purge --dry-run --yes >/dev/null 2>&1
    local ok=1
    [[ -f "$h/.config/minecraft-splitscreen/curseforge-api-key" ]] || ok=0
    [[ -f "$h/.local/share/PolyMC/instances/latestUpdate-1/world.dat" ]] || ok=0
    [[ -f "$h/Desktop/MinecraftSplitscreen.desktop" ]] || ok=0
    _expect "T2.3 --purge --dry-run deletes nothing" "$ok" "1"
    _teardown
}

# --- T3: what --purge must NOT touch -----------------------------------------

test_keep_data_spares_byok_key() {
    _setup
    local h; h="$(_fake_install)"
    HOME="$h" bash "$UNINSTALL" --keep-data --yes >/dev/null 2>&1
    _expect_exists "T3.1 --keep-data spares the BYOK key" \
        "$h/.config/minecraft-splitscreen/curseforge-api-key"
    _teardown
}

test_full_uninstall_spares_byok_key() {
    # Without --purge the key survives on purpose: a reinstall should not have
    # to re-prompt for it. Only --purge is "leave no trace".
    _setup
    local h; h="$(_fake_install)"
    printf 'n\ny\n' | HOME="$h" bash "$UNINSTALL" >/dev/null 2>&1
    _expect_exists "T3.2 a full (non-purge) uninstall spares the BYOK key" \
        "$h/.config/minecraft-splitscreen/curseforge-api-key"
    _teardown
}

test_keep_data_spares_worlds() {
    _setup
    local h; h="$(_fake_install)"
    HOME="$h" bash "$UNINSTALL" --keep-data --yes >/dev/null 2>&1
    _expect_exists "T3.3 --keep-data spares instances/worlds" \
        "$h/.local/share/PolyMC/instances/latestUpdate-1/world.dat"
    _teardown
}

# --- T4: shortcuts.vdf surgery -----------------------------------------------

test_vdf_round_trips_exactly() {
    _setup
    local h; h="$(_fake_install)"
    local cfg; cfg="$(_fake_steam "$h" | cut -d' ' -f2)"
    local got
    got="$(python3 - "$REMOVER" "$cfg/shortcuts.vdf" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("r", sys.argv[1])
r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
d = open(sys.argv[2], "rb").read()
root, trailer = r.parse_shortcuts(d)
print("exact" if r.serialize_shortcuts(root, trailer) == d else "lossy")
PY
)"
    _expect "T4.1 parse+serialize reproduces the file byte for byte" \
        "$got" "exact"
    _teardown
}

test_vdf_keeps_foreign_shortcuts() {
    _setup
    local h; h="$(_fake_install)"
    local cfg; cfg="$(_fake_steam "$h" | cut -d' ' -f2)"
    HOME="$h" python3 "$REMOVER" --force >/dev/null 2>&1
    _expect "T4.2 foreign shortcuts survive, renumbered contiguously" \
        "$(_shortcut_names "$cfg/shortcuts.vdf")" "0:RetroArch 1:Heroic Games"
    _teardown
}

test_vdf_removes_our_artwork_only() {
    _setup
    local h; h="$(_fake_install)"
    local out appid cfg
    out="$(_fake_steam "$h")"; appid="${out%% *}"; cfg="${out#* }"
    HOME="$h" python3 "$REMOVER" --force >/dev/null 2>&1
    local ours_left foreign_left
    ours_left="$(find "$cfg/grid" -name "${appid}*" | wc -l)"
    foreign_left="$(find "$cfg/grid" -name '2172748561*' | wc -l)"
    _expect "T4.3 our artwork removed, foreign artwork kept" \
        "$ours_left/$foreign_left" "0/1"
    _teardown
}

test_vdf_writes_a_backup() {
    _setup
    local h; h="$(_fake_install)"
    local cfg; cfg="$(_fake_steam "$h" | cut -d' ' -f2)"
    HOME="$h" python3 "$REMOVER" --force >/dev/null 2>&1
    local n; n="$(find "$cfg" -name 'shortcuts.vdf.mcss-backup-*' | wc -l)"
    _expect "T4.4 a backup is written before rewriting" "$n" "1"
    _teardown
}

test_vdf_dry_run_writes_nothing() {
    _setup
    local h; h="$(_fake_install)"
    local cfg; cfg="$(_fake_steam "$h" | cut -d' ' -f2)"
    local before after
    before="$(md5sum < "$cfg/shortcuts.vdf")"
    HOME="$h" python3 "$REMOVER" --dry-run >/dev/null 2>&1
    after="$(md5sum < "$cfg/shortcuts.vdf")"
    _expect "T4.5 --dry-run leaves shortcuts.vdf byte-identical" \
        "$after" "$before"
    _teardown
}

test_vdf_dry_run_spares_artwork() {
    # The vdf and the artwork are deleted by different code paths, so proving
    # the file is untouched proves nothing about the PNGs. A "dry run" that
    # deletes the user's library art is not a dry run.
    _setup
    local h; h="$(_fake_install)"
    local out appid cfg
    out="$(_fake_steam "$h")"; appid="${out%% *}"; cfg="${out#* }"
    local before after
    before="$(find "$cfg/grid" -type f | wc -l)"
    HOME="$h" python3 "$REMOVER" --dry-run >/dev/null 2>&1
    after="$(find "$cfg/grid" -type f | wc -l)"
    _expect "T4.8 --dry-run deletes no grid artwork" "$after" "$before"
    _teardown
}

test_vdf_round_trip_guard_blocks_the_write() {
    # T4.1 proves the round trip currently holds; this proves the GUARD does
    # its job when it does not. Every file that parses also round-trips today,
    # so the only way to exercise the refusal is to make serialization lossy
    # on purpose — which is exactly the regression the guard exists to catch
    # if the parser is ever extended.
    _setup
    local h; h="$(_fake_install)"
    local cfg; cfg="$(_fake_steam "$h" | cut -d' ' -f2)"
    local got
    got="$(python3 - "$REMOVER" "$cfg/shortcuts.vdf" <<'PY'
import importlib.util, sys, hashlib
spec = importlib.util.spec_from_file_location("r", sys.argv[1])
r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
path = sys.argv[2]
before = hashlib.md5(open(path, "rb").read()).hexdigest()
original = r.serialize_shortcuts
r.serialize_shortcuts = lambda a, b: original(a, b) + b"\x00"   # lossy
try:
    r.process(path, "", False)
    outcome = "WROTE"
except r.VdfError:
    outcome = "refused"
except Exception as e:                       # noqa: BLE001 - any other failure is also a miss
    outcome = f"wrong-error:{type(e).__name__}"
after = hashlib.md5(open(path, "rb").read()).hexdigest()
print(f"{outcome}/{'unchanged' if before == after else 'MODIFIED'}")
PY
)"
    _expect "T4.9 a lossy round trip refuses and leaves the file alone" \
        "$got" "refused/unchanged"
    _teardown
}

test_vdf_is_idempotent() {
    _setup
    local h; h="$(_fake_install)"
    local cfg; cfg="$(_fake_steam "$h" | cut -d' ' -f2)"
    HOME="$h" python3 "$REMOVER" --force >/dev/null 2>&1
    local after_first rc=0
    after_first="$(md5sum < "$cfg/shortcuts.vdf")"
    HOME="$h" python3 "$REMOVER" --force >/dev/null 2>&1 || rc=$?
    local after_second; after_second="$(md5sum < "$cfg/shortcuts.vdf")"
    if [[ "$after_first" == "$after_second" && $rc -eq 0 ]]; then
        _pass "T4.6 a second run is a clean no-op"
    else
        _fail "T4.6 a second run is a clean no-op" "rc=$rc, file changed"
    fi
    _teardown
}

test_vdf_refuses_unparseable_file() {
    # An unrecognised file must be left ALONE. Splicing bytes we do not
    # understand is how a user loses every non-Steam shortcut they have.
    _setup
    local h; h="$(_fake_install)"
    local cfg="$h/.steam/steam/userdata/12345678/config"
    mkdir -p "$cfg"
    printf '\x00shortcuts\x00\x00""0\x00\x07garbage\x00\x08\x08' \
        > "$cfg/shortcuts.vdf"
    local before after rc=0
    before="$(md5sum < "$cfg/shortcuts.vdf")"
    HOME="$h" python3 "$REMOVER" --force >/dev/null 2>&1 || rc=$?
    after="$(md5sum < "$cfg/shortcuts.vdf")"
    if (( rc != 0 )) && [[ "$before" == "$after" ]]; then
        _pass "T4.7 an unparseable vdf is refused and left untouched"
    else
        _fail "T4.7 an unparseable vdf is refused and left untouched" \
              "rc=$rc, changed=$([[ "$before" == "$after" ]] && echo no || echo YES)"
    fi
    _teardown
}

# --- T6: podman store accounting ---------------------------------------------
# Found on the Deck 2026-08-01: because a dry run removes nothing, the
# "is the store empty?" counts still included OUR OWN container and image, so
# the dry run announced "kept — you have other containers" on a machine where
# the real run finds nothing left and removes the store. A dry run that
# predicts the opposite of the real outcome is worse than one that says
# nothing. Neither podman nor distrobox exists in CI, so both are faked.

# _fake_podman: Put a stub podman (and distrobox) on PATH.
# Inputs:
#   $1 — total containers reported by `podman ps -aq`
#   $2 — total images reported by `podman images -q`
#   (both INCLUDING our own box/image, as the real thing would report them)
# Outputs: stdout — a directory to prepend to PATH
_fake_podman() {
    local containers="$1" images="$2"
    local bin="$TMPDIR_TEST/bin"
    mkdir -p "$bin"
    cat > "$bin/podman" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "ps -aq")      for i in \$(seq 1 $containers); do echo "c\$i"; done ;;
  "images -q")   for i in \$(seq 1 $images);     do echo "i\$i"; done ;;
  "container exists") exit 0 ;;
  "image exists")     exit 0 ;;
  "rm -f")       exit 0 ;;
  "rmi "*|"rmi") exit 0 ;;
  "unshare rm")  shift 2; rm -rf "\$@" 2>/dev/null; exit 0 ;;
  *)             exit 0 ;;
esac
EOF
    cat > "$bin/distrobox" <<'EOF'
#!/bin/bash
[[ "$1" == "list" ]] && echo "ID | NAME              | STATUS" && \
    echo "abc123 | mcss-evsieve-build | Up"
exit 0
EOF
    chmod +x "$bin/podman" "$bin/distrobox"
    echo "$bin"
}

test_dry_run_predicts_store_removal() {
    # Ours are the ONLY container and image, so the real run would leave the
    # store empty — the dry run must say so.
    _setup
    local h; h="$(_fake_install)"
    local bin; bin="$(_fake_podman 1 1)"
    mkdir -p "$h/.local/share/containers"
    local out
    out="$(PATH="$bin:$PATH" HOME="$h" bash "$UNINSTALL" --purge --dry-run --yes 2>&1)"
    if grep -q 'Would remove empty podman store' <<<"$out"; then
        _pass "T6.1 dry run predicts removing the store when only ours remain"
    else
        _fail "T6.1 dry run predicts removing the store when only ours remain" \
              "got: $(grep -i 'podman store\|Kept /' <<<"$out" | head -1)"
    fi
    _teardown
}

test_dry_run_predicts_keeping_a_shared_store() {
    # A foreign container exists, so the store must be kept — and the dry run
    # must not claim otherwise.
    _setup
    local h; h="$(_fake_install)"
    local bin; bin="$(_fake_podman 2 2)"
    mkdir -p "$h/.local/share/containers"
    local out
    out="$(PATH="$bin:$PATH" HOME="$h" bash "$UNINSTALL" --purge --dry-run --yes 2>&1)"
    if grep -q 'Kept .*containers — you have other podman' <<<"$out"; then
        _pass "T6.2 dry run keeps the store when a foreign container exists"
    else
        _fail "T6.2 dry run keeps the store when a foreign container exists" \
              "got: $(grep -i 'podman store\|Kept /' <<<"$out" | head -1)"
    fi
    _teardown
}

test_real_run_never_touches_a_shared_store() {
    # The blast-radius rule (PRINCIPLES #7): someone else's containers are not
    # ours to delete, so a populated store survives a REAL purge.
    _setup
    local h; h="$(_fake_install)"
    local bin; bin="$(_fake_podman 3 3)"
    mkdir -p "$h/.local/share/containers/storage"
    PATH="$bin:$PATH" HOME="$h" bash "$UNINSTALL" --purge --yes >/dev/null 2>&1
    _expect_exists "T6.3 a populated podman store survives a real purge" \
        "$h/.local/share/containers/storage"
    _teardown
}

# --- T5: the Steam-is-running guard ------------------------------------------

test_refuses_while_steam_runs() {
    # Steam holds shortcuts.vdf in memory and rewrites it on exit, so an edit
    # made now would be silently reverted — reporting success would be a lie.
    _setup
    local h; h="$(_fake_install)"
    local cfg; cfg="$(_fake_steam "$h" | cut -d' ' -f2)"

    # A process whose comm is exactly "steam". Tracked by PID and killed by
    # PID — never a name-matched kill (PRINCIPLES #7).
    cp /bin/sleep "$TMPDIR_TEST/steam"
    "$TMPDIR_TEST/steam" 30 &
    local steam_pid=$!
    sleep 0.3

    local before after rc=0
    before="$(md5sum < "$cfg/shortcuts.vdf")"
    HOME="$h" python3 "$REMOVER" >/dev/null 2>&1 || rc=$?
    after="$(md5sum < "$cfg/shortcuts.vdf")"

    kill "$steam_pid" 2>/dev/null || true
    wait "$steam_pid" 2>/dev/null || true

    if (( rc == 2 )) && [[ "$before" == "$after" ]]; then
        _pass "T5.1 refuses (exit 2) and edits nothing while Steam runs"
    else
        _fail "T5.1 refuses (exit 2) and edits nothing while Steam runs" \
              "rc=$rc (wanted 2), file changed=$([[ "$before" == "$after" ]] && echo no || echo YES)"
    fi
    _teardown
}

run_all_tests() {
    echo "=== uninstall --purge + remove-from-steam.py ==="
    test_purge_and_keep_data_conflict
    test_conflict_is_order_independent
    test_conflict_deletes_nothing
    test_purge_removes_byok_key
    test_purge_removes_meta_cache
    test_purge_dry_run_removes_nothing
    test_keep_data_spares_byok_key
    test_full_uninstall_spares_byok_key
    test_keep_data_spares_worlds
    test_vdf_round_trips_exactly
    test_vdf_keeps_foreign_shortcuts
    test_vdf_removes_our_artwork_only
    test_vdf_writes_a_backup
    test_vdf_dry_run_writes_nothing
    test_vdf_dry_run_spares_artwork
    test_vdf_round_trip_guard_blocks_the_write
    test_vdf_is_idempotent
    test_vdf_refuses_unparseable_file
    test_dry_run_predicts_store_removal
    test_dry_run_predicts_keeping_a_shared_store
    test_real_run_never_touches_a_shared_store
    test_refuses_while_steam_runs
    echo ""
    echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
    if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
        exit 0
    else
        exit 1
    fi
}

run_all_tests
