#!/bin/bash
# =============================================================================
# probe-controller-reconnect.sh — does Steam reuse the SAME 28de:11ff virtual
#                                  pad across a physical unplug/replug, or does
#                                  it mint a fresh one?
# =============================================================================
# Answers the open question behind issue #38 / docs/RESEARCH-CONTROLLER-IDENTITY-
# 2026-07-01.md: our default controller path already binds a Steam VIRTUAL pad's
# device nodes into the sandbox (_map_external_player_virtuals), not the physical
# pad's own raw nodes. If that virtual's eventN/jsN survives a physical disconnect/
# reconnect unchanged, seamless reconnect may already be one rebind step away. If
# Steam mints a NEW virtual (new eventN/jsN) on reconnect, our bwrap sandbox — bound
# to the OLD path at launch and fixed thereafter — can never recover it, and the
# real fix is the persistent uinput-proxy device #38 proposes.
#
# This script polls _map_external_player_virtuals directly (no orchestrator, no
# sandbox, no launch) and reports, per external vendor:product, whether the claimed
# virtual's event/js changes across a disconnect → reconnect cycle.
#
# USAGE (on the Deck, Desktop or Game Mode terminal):
#   bash tests/probe-controller-reconnect.sh
#   Then, with ONE external controller (DS4/Xbox/8BitDo) already connected or not:
#     1. Plug it in if it isn't already — wait for "CLAIMED" (may take a few
#        seconds; Steam mints virtuals with a delay, per this project's own notes).
#     2. Unplug it. Wait for "DISAPPEARED".
#     3. Wait ~5s, then plug the SAME controller back in.
#     4. Read the verdict: "STABLE" (same event/js reused) or "CHANGED" (new
#        virtual minted — confirms the uinput-proxy fix in #38 is required).
#   Repeat a few times (fast replug, slow replug, USB vs Bluetooth) for confidence.
#   Ctrl+C to stop. Test ONE controller at a time — vendor:product alone can't
#   disambiguate two identical pads (documented limitation, same as production).
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="${MCSS_MODULES:-$HOME/.local/share/PolyMC/modules}"
# shellcheck source=/dev/null
source "$MODULES/controller_monitor.sh" 2>/dev/null || source "$HERE/../modules/controller_monitor.sh"

if ! declare -f _map_external_player_virtuals >/dev/null 2>&1; then
    echo "ERROR: _map_external_player_virtuals not found — controller_monitor.sh failed to source" >&2
    exit 1
fi

echo "=============================================================================="
echo " Controller reconnect-identity probe"
echo "=============================================================================="
echo " 1. Plug in ONE external controller (if not already). Wait for CLAIMED."
echo " 2. Unplug it. Wait for DISAPPEARED."
echo " 3. Wait ~5s, then plug the SAME controller back in."
echo " 4. Read the verdict line: STABLE (reconnect may 'just work' already) or"
echo "    CHANGED (Steam minted a new virtual — confirms #38's uinput-proxy fix"
echo "    is the real path forward, not a rebind tweak)."
echo " Ctrl+C to stop. One controller at a time — see the script header for why."
echo "=============================================================================="
echo

declare -A LAST_CLAIM=()     # key "vendor:product" -> "event js" (last time it was present)
declare -A EVER_SEEN=()      # key -> 1 once claimed at least once
declare -A AWAITING=()       # key -> 1 while disappeared, waiting to see if it comes back

while true; do
    declare -A CURRENT=()

    while IFS=' ' read -r ev js ven prod; do
        [[ -z "$ev" ]] && continue
        key="${ven}:${prod}"
        CURRENT["$key"]="${ev} ${js}"

        if [[ -z "${EVER_SEEN[$key]:-}" ]]; then
            echo "$(date +%T)  CLAIMED   [$key] -> event${ev} js${js}  (first time seen)"
            EVER_SEEN["$key"]=1
        elif [[ -n "${AWAITING[$key]:-}" ]]; then
            # It was gone last pass and is back now — this is the reconnect moment.
            prev="${LAST_CLAIM[$key]:-}"
            cur="${ev} ${js}"
            if [[ "$prev" == "$cur" ]]; then
                echo "$(date +%T)  RECLAIMED [$key] -> event${ev} js${js}   ✅ STABLE — same virtual reused across the disconnect"
            else
                echo "$(date +%T)  RECLAIMED [$key] -> event${ev} js${js}   ⚠️  CHANGED — was '${prev}', Steam minted a NEW virtual"
            fi
            unset 'AWAITING[$key]'
        fi
        LAST_CLAIM["$key"]="${ev} ${js}"
    done < <(_map_external_player_virtuals 2>/dev/null)

    # Anything that was claimed before but isn't in this pass's output has disappeared.
    for key in "${!EVER_SEEN[@]}"; do
        if [[ -z "${CURRENT[$key]:-}" && -z "${AWAITING[$key]:-}" ]]; then
            echo "$(date +%T)  DISAPPEARED [$key] -> was event/js '${LAST_CLAIM[$key]:-?}' — waiting for reconnect..."
            AWAITING["$key"]=1
        fi
    done

    sleep 1
done
