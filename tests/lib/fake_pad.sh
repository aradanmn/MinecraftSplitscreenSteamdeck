#!/bin/bash
set -uo pipefail

# =============================================================================
# fake_pad.sh — CI protocol double for tests/lib/uhid_pad.py
# =============================================================================
# TEST TOOLING (#136 / build plan #157, PR-2). /dev/uhid does not exist on a
# GitHub runner, so tests/test_uhid_rig.sh points MCSS_RIG_PAD_CMD (the CI
# seam documented in tests/lib/uhid_rig.sh) at this fixture instead of the
# real primitive. It speaks the same stdin/stdout protocol and touches no
# device, so uhid_rig.sh's lifecycle logic — the bulk of PR-2's risk — gets
# real CI coverage instead of shipping untested.
#
# PROTOCOL CONTRACT — MUST be kept in lockstep with tests/lib/uhid_pad.py.
# This is a deliberate, acknowledged second encoding (PRINCIPLES #9 flags
# this exact tradeoff); mitigated by tests/test_uhid_rig.sh asserting the
# real uhid_pad.py --help still advertises the flags this fixture assumes, so
# a drift in the primitive fails here instead of on the Deck. If
# uhid_pad.py's protocol ever changes, this file changes with it:
#   argv:  create --uniq U --name N --vendor V --product P
#   stdin (one command per line):
#     press <BTN> | release <BTN> | hold <BTN> <ms> | axis <NAME> <0-255>
#     neutral | destroy | quit | exit
#   readiness: "created uniq=<uniq> name=<name>" on stdout (unless
#     FAKE_PAD_NEVER_READY=1).
#   ack: "ok <cmd>" on stdout per ACCEPTED command; a malformed/unknown
#     command prints "bad command '<line>': <reason>" to stderr and prints
#     NO ack — this asymmetry is what rig_inject's error handling relies on.
#   lifetime: exits on destroy/quit/exit OR on stdin EOF (the EOF path is
#     what the rig's fd-ordering mutations M3/M4 attack).
#
# Environment overrides (test-only knobs, not part of uhid_pad.py's contract):
#   FAKE_PAD_NEVER_READY  — "1": never print the "created" line (feeds the
#                           rig's readiness-timeout test).
#   FAKE_PAD_IGNORE_TERM  — "1": trap '' TERM (feeds the rig's SIGKILL-rung
#                           test).
#   FAKE_PAD_SLOW_EXIT_S  — sleep this many seconds before exiting on
#                           destroy/quit/exit.
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.0 2026-08-01  #136 PR-2: initial fixture.
# =============================================================================

# _known_button: Mirrors uhid_pad.py's BUTTONS dict keys — enough to make
# "unknown button" rejection exercise the same ack/no-ack asymmetry, without
# re-encoding the HID report layout (that stays uhid_pad.py's job).
_known_button() {
    case "$1" in
        BTN_SOUTH|BTN_EAST|BTN_C|BTN_NORTH|BTN_WEST|BTN_Z|BTN_TL|BTN_TR| \
        BTN_TL2|BTN_TR2|BTN_SELECT|BTN_START)
            return 0 ;;
        *) return 1 ;;
    esac
}

# _known_axis: Mirrors uhid_pad.py's AXES dict keys.
_known_axis() {
    case "$1" in
        LX|LY|RX|RY) return 0 ;;
        *) return 1 ;;
    esac
}

if [[ "${FAKE_PAD_IGNORE_TERM:-0}" == "1" ]]; then
    # shellcheck disable=SC2064  # intentional immediate (empty) expansion —
    # this IS the no-op TERM handler, not a deferred command.
    trap '' TERM
fi

mode="${1:-}"
shift || true
if [[ "$mode" != "create" ]]; then
    echo "fake_pad.sh: unsupported mode '$mode' (only 'create')" >&2
    exit 2
fi

uniq="" name=""
while (( $# > 0 )); do
    case "$1" in
        --uniq)    uniq="${2:-}"; shift 2 ;;
        --name)    name="${2:-}"; shift 2 ;;
        --vendor)  shift 2 ;;
        --product) shift 2 ;;
        *)         shift ;;
    esac
done

if [[ "${FAKE_PAD_NEVER_READY:-0}" != "1" ]]; then
    echo "created uniq=$uniq name=$name"
fi

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r cmd arg1 arg2 <<< "$line"
    case "$cmd" in
        destroy|quit|exit)
            break
            ;;
        press|release)
            if _known_button "$arg1"; then
                echo "ok $cmd"
            else
                echo "bad command '$line': unknown button '$arg1'" >&2
            fi
            ;;
        hold)
            if _known_button "$arg1" && [[ "$arg2" =~ ^[0-9]+$ ]]; then
                sleep "$(awk -v ms="$arg2" 'BEGIN { print ms / 1000 }')"
                echo "ok $cmd"
            else
                echo "bad command '$line': bad hold arguments" >&2
            fi
            ;;
        axis)
            if _known_axis "$arg1" && [[ "$arg2" =~ ^[0-9]+$ ]] \
                && (( arg2 >= 0 && arg2 <= 255 ))
            then
                echo "ok $cmd"
            else
                echo "bad command '$line': bad axis arguments" >&2
            fi
            ;;
        neutral)
            echo "ok $cmd"
            ;;
        *)
            echo "bad command '$line': unknown command '$cmd'" >&2
            ;;
    esac
done

if [[ -n "${FAKE_PAD_SLOW_EXIT_S:-}" ]]; then
    sleep "$FAKE_PAD_SLOW_EXIT_S"
fi
exit 0
