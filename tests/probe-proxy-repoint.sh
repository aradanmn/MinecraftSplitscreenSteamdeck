#!/bin/bash
# =============================================================================
# probe-proxy-repoint.sh — D2-CONFIRM: does controller_proxy.sh's symlink
#                          re-point resume forwarding through a LIVE evsieve
#                          after the physical pad re-enumerates on a NEW
#                          eventN, without a process restart?  (issue #38)
# =============================================================================
# Operator-interactive, single-session on-Deck probe. Owner has ONE external
# DS4 (BT or USB); Steam runs in Game Mode. Exercises the REAL
# controller_proxy.sh public API (proxy_start_slot/proxy_virtual_nodes/
# proxy_repoint_slot/proxy_stop_slot) — this is not a mock/stub harness like
# tests/test_controller_proxy.sh, it is the #38 M1/PR2 spike §F Deck driver
# that answers the still-open D2 CONFIRM question (spec §G):
#
#   D2 CONFIRMED  (H5=RESUMES) -> PR4 reconnect calls proxy_repoint_slot
#                                 (seamless resume, no relaunch)
#   D2-alt        (H5=SILENT)  -> PR4 calls proxy_stop_slot+proxy_start_slot
#                                 on reconnect (relaunch fallback)
#
# Reuses (by SOURCING, not copying) tests/probe-evsieve-reconnect.sh's
# helper functions and cleanup/trap tracked-pid discipline: cleanup,
# record_virtual_node, capture_stream, _dual_capture, _fidelity_matches,
# _tally_is_empty, wait_for_ds4, prompt_operator, announce_wiggle,
# emit_verdict, _start_node_watcher, find_ds4_event_node, plus the
# RESULTS/LINK_DIR/DS4_VENDOR/CAPTURE_SECONDS/RECONNECT_WAIT_S constants and
# _evsieve_logfile/_nodewatch_logfile/_udev_logfile naming. That file's own
# "Main flow" (probes P0/A/B) is guarded (BASH_SOURCE[0]==$0) so sourcing it
# here loads only its functions/constants — see its v1.1 history line.
#
# H5  REPOINT      RESUMES (D2 confirmed) vs SILENT (D2-alt) after a
#                  proxy_repoint_slot to a forced NEW eventN
# H6  VIRT_JS      the virtual evdev's inode/majmin/js stay STABLE across a
#                  same-path reconnect (battery-death cycle, no repoint yet
#                  needed — evsieve's own persist=reopen should just work)
# H7  TEARDOWN     proxy_stop_slot leaves no evsieve process and no
#                  dangling symlink in either proxy dir
#
# HARD RULES: no sudo; never grab/target 28de:* or the built-in; never kill
# Steam/gamescope; only kill evsieve PIDs THIS script (via controller_proxy.
# sh) started; trap cleanup leaves no lingering evsieve. Same discipline as
# tests/probe-evsieve-reconnect.sh.
#
# USAGE (on the Deck, Game Mode terminal or Desktop):
#   bash tests/probe-proxy-repoint.sh
#   Follow the on-screen prompts with ONE external DS4.
#
# Environment overrides (for testing):
#   MCSS_EVSIEVE_BIN   — path to evsieve (default: runtime_context.sh's
#                        Group B default, PR1's build-at-install binary —
#                        $MCSS_LAUNCHER_ROOT/bin/evsieve)
#   MCSS_MODULES       — deployed module dir (default the house path; same
#                        override as probe-evsieve-reconnect.sh)
#   MCSS_PROBE_RESULTS — results file (default $HOME/proxy-repoint-probe-
#                        <timestamp>.txt; set BEFORE sourcing the shared
#                        probe file below so its RESULTS default honors it)
#
# Version history:
#   v1.0 2026-07-19  #38 M1/PR2 spike §F: D2-CONFIRM Deck driver for
#                    controller_proxy.sh (H5/H6/H7)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="${MCSS_MODULES:-$HOME/.local/share/PolyMC/modules}"

# Repoint-probe-specific results filename — set BEFORE sourcing the shared
# probe file so its own RESULTS="${MCSS_PROBE_RESULTS:-...}" default picks
# this up instead of its evsieve-probe-<ts>.txt name.
: "${MCSS_PROBE_RESULTS:=$HOME/proxy-repoint-probe-$(date +%Y%m%d-%H%M%S).txt}"
export MCSS_PROBE_RESULTS

# --- Shared probe harness (SOURCED, not copied — its Main flow is guarded
# so this only loads functions/constants: cleanup+trap discipline,
# record_virtual_node, capture_stream/_dual_capture/_fidelity_matches/
# _tally_is_empty, wait_for_ds4, prompt_operator, announce_wiggle,
# emit_verdict, _start_node_watcher, find_ds4_event_node, RESULTS/LINK_DIR/
# DS4_VENDOR/CAPTURE_SECONDS/RECONNECT_WAIT_S, _evsieve_logfile/
# _nodewatch_logfile/_udev_logfile). Unlike the modules/ cascade below,
# tests/ is checkout-only — it is never part of the deployed tree — so
# this always resolves relative to THIS script's own directory. Sourced
# FIRST, before controller_proxy.sh: it brings in controller_monitor.sh
# itself (its own internal cascade), and that module's constants block is
# NOT re-source-safe (no readonly guard) — sourcing it a second time here
# would abort with "readonly variable". controller_proxy.sh is sourced
# only once, below, so it has no such hazard.
# shellcheck source=/dev/null
source "$HERE/probe-evsieve-reconnect.sh"

# --- Real module under test (controller_proxy.sh — NOT stubbed) ---
# shellcheck source=/dev/null
source "$MODULES/controller_proxy.sh" 2>/dev/null \
    || source "$HERE/../modules/controller_proxy.sh"

_required_fn=""
for _required_fn in proxy_start_slot proxy_virtual_nodes proxy_repoint_slot \
    proxy_stop_slot record_virtual_node find_ds4_event_node emit_verdict \
    wait_for_ds4 prompt_operator announce_wiggle capture_stream \
    _fidelity_matches _tally_is_empty _extract_field _start_node_watcher \
    _stop_watchers _evsieve_logfile _nodewatch_logfile; do
    if ! declare -f "$_required_fn" >/dev/null 2>&1; then
        echo "ERROR: ${_required_fn} not found — a required module/probe" \
             "file failed to source" >&2
        exit 1
    fi
done
unset _required_fn

# probe-evsieve-reconnect.sh's own sourcing turns on `set -euo pipefail`
# (its controller_monitor.sh source line does); re-assert our mode so a
# soft failure (e.g. a `[[ -e ]] &&` miss) reaches its verdict line instead
# of aborting the whole operator session — same rationale as that probe's
# own re-assertion right after its module source.
set +e
set -uo pipefail

readonly PROXY_SLOT=1

# _find_ds4_vendor_product: Look up TARGET_EV's vendor/product via
# _parse_all_gamepad_devices (ambient from controller_monitor.sh) — needed
# because find_ds4_event_node only returns "eventN jsN", and
# proxy_start_slot's device-id argument wants vendor:product (spike §A).
# Inputs:
#   $1 — target eventN (bare number, no "event" prefix)
# Outputs:
#   stdout — "<vendor> <product>" on match
#   return — 1 if TARGET_EV is not currently enumerated
_find_ds4_vendor_product() {
    local target_ev="$1" ev js vnd prd sysfs phys
    # shellcheck disable=SC2034  # sysfs/phys are positional fields of
    # _parse_all_gamepad_devices' fixed 6-column contract; only ev/vnd/prd
    # are used here but all must be read to keep columns aligned.
    while IFS=' ' read -r ev js vnd prd sysfs phys; do
        [[ "$ev" == "$target_ev" ]] || continue
        echo "$vnd $prd"
        return 0
    done < <(_parse_all_gamepad_devices 2>/dev/null)
    return 1
}

# _confirm_proxy_dead: True if PROXY_SLOT has no live evsieve tracked by
# controller_proxy.sh's own pidfile (see that module's header
# "Implementation note" — the pidfile, not the in-process cache, is the
# subshell-safe record). Used only for H7's teardown assertion.
# Inputs: $1 — slot number
_confirm_proxy_dead() {
    local slot="$1" pidfile
    pidfile="${MCSS_HELPER_DIR}/proxy-slot${slot}.pid"
    [[ -f "$pidfile" ]] || return 0
    local pid
    pid=$(<"$pidfile")
    [[ -z "$pid" ]] && return 0
    ! kill -0 "$pid" 2>/dev/null
}

_print_banner() {
    echo "=============================================================="
    echo " controller_proxy.sh repoint probe (issue #38, D2-CONFIRM)"
    echo "=============================================================="
    echo " Connect ONE external DS4 (BT or USB). Steam should be running"
    echo " in Game Mode. This probe will:"
    echo "   - proxy_start_slot the DS4's own 054c evdev node through"
    echo "     controller_proxy.sh (never the Deck's built-in 28de:11ff)"
    echo "   - simulate a battery-death power-cycle (same eventN expected)"
    echo "   - then ask you to force a NEW eventN (e.g. replug via a"
    echo "     different USB port, or a fresh BT pair) and repoint"
    echo "   - never restart or kill Steam/gamescope"
    echo "   - only kill evsieve processes controller_proxy.sh starts"
    echo " Ctrl+C is safe at any point; cleanup runs automatically and"
    echo " leaves no evsieve process behind."
    echo " Results are written to: ${RESULTS}"
    echo "=============================================================="
    echo
}

# --- Main flow ---

_print_banner

bin=""
if ! bin=$(_proxy_evsieve_bin); then
    emit_verdict H5_REPOINT FAIL \
        "MCSS_EVSIEVE_BIN unresolved/non-executable — cannot run this probe"
    exit 1
fi
echo "[probe] using evsieve: ${bin}" >&2

if ! find_ds4_event_node >/dev/null 2>&1; then
    prompt_operator "Connect your ONE external DS4 controller (USB or" \
        " Bluetooth) now, then press Enter." || true
fi

ds4="" rc=0
ds4=$(find_ds4_event_node)
rc=$?
if (( rc == 2 )); then
    emit_verdict H5_REPOINT OPERATOR_ABORT \
        "operator skipped the multi-pad guard; aborting probe"
    exit 1
elif (( rc != 0 )); then
    emit_verdict H5_REPOINT FAIL \
        "no 054c js-bearing pad detected; cannot proceed"
    exit 1
fi
ev_orig="${ds4%% *}"

vnd_prd="" vnd="" prd=""
if vnd_prd=$(_find_ds4_vendor_product "$ev_orig"); then
    vnd="${vnd_prd%% *}"
    prd="${vnd_prd#* }"
else
    vnd="$DS4_VENDOR"
    prd="0000"
    echo "[probe] WARN: could not resolve product id for event${ev_orig};" \
         "falling back to product=0000 (device-id cosmetic only, ALLOW" \
         "stays keyed off vendor per D3)" >&2
fi

_start_node_watcher "/dev/input/event${ev_orig}"

echo "[probe] starting proxy: slot=${PROXY_SLOT}" \
     "event${ev_orig} ${vnd}:${prd}" >&2
pid=""
if ! pid=$(proxy_start_slot "$PROXY_SLOT" "/dev/input/event${ev_orig}" \
    "$vnd" "$prd"); then
    rc=$?
    emit_verdict H5_REPOINT FAIL \
        "proxy_start_slot failed (rc=${rc}) — cannot proceed"
    exit 1
fi
echo "[probe] evsieve pid=${pid}" >&2

virt_pair="" virt_ev="" virt_js=""
if ! virt_pair=$(proxy_virtual_nodes "$PROXY_SLOT"); then
    emit_verdict H6_VIRT_JS FAIL \
        "proxy_virtual_nodes never resolved a jsN for slot ${PROXY_SLOT}"
    proxy_stop_slot "$PROXY_SLOT"
    exit 1
fi
virt_ev="${virt_pair%% *}"
virt_js="${virt_pair#* }"
echo "[probe] virtual nodes: ${virt_ev} ${virt_js}" >&2

pre_tally=$(record_virtual_node "${MCSS_PROXY_VIRT_DIR}/slot${PROXY_SLOT}" \
    "MCSS-slot${PROXY_SLOT}")
echo "[probe] pre-cycle virtual identity: ${pre_tally}" >&2

# --- Battery-death + reconnect (same eventN expected) -----------------
if ! prompt_operator "Power the DS4 OFF now (hold PS ~10s until the" \
    " lightbar dies) to simulate battery death. Wait for it to" \
    " disappear, then press Enter."
then
    emit_verdict H6_VIRT_JS FAIL "operator skipped the power-cycle step"
    proxy_stop_slot "$PROXY_SLOT"
    exit 1
fi

waited=0 gone=0
while (( waited < RECONNECT_WAIT_S )); do
    if ! find_ds4_event_node >/dev/null 2>&1; then
        gone=1
        break
    fi
    sleep 1
    waited=$(( waited + 1 ))
done
(( gone )) || echo "[probe] WARN: DS4 still enumerated" >&2

if ! prompt_operator "Now power the DS4 back ON (same transport — BT or" \
    " USB). Press Enter."
then
    emit_verdict H6_VIRT_JS FAIL "operator skipped reconnect"
    proxy_stop_slot "$PROXY_SLOT"
    exit 1
fi

if ! wait_for_ds4 "$RECONNECT_WAIT_S"; then
    emit_verdict H6_VIRT_JS FAIL \
        "DS4 did not reappear within ${RECONNECT_WAIT_S}s"
    proxy_stop_slot "$PROXY_SLOT"
    exit 1
fi
sleep 2

post_tally=$(record_virtual_node \
    "${MCSS_PROXY_VIRT_DIR}/slot${PROXY_SLOT}" "MCSS-slot${PROXY_SLOT}")
echo "[probe] post-cycle virtual identity: ${post_tally}" >&2

pre_inode=$(_extract_field inode "$pre_tally")
post_inode=$(_extract_field inode "$post_tally")
pre_path=$(_extract_field realpath "$pre_tally")
post_path=$(_extract_field realpath "$post_tally")
pre_mm=$(_extract_field majmin "$pre_tally")
post_mm=$(_extract_field majmin "$post_tally")
pre_js=$(_extract_field js "$pre_tally")
post_js=$(_extract_field js "$post_tally")

h6_verdict="CHANGED"
if [[ "$pre_inode" == "$post_inode" && "$pre_inode" != "NONE" \
    && "$pre_path" == "$post_path" && "$pre_mm" == "$post_mm" \
    && "$pre_js" == "$post_js" && "$pre_js" != "NONE" ]]
then
    h6_verdict="STABLE"
fi
h6_evidence="pre[${pre_tally}] post[${post_tally}]"
h6_evidence+=" (same-eventN reconnect, no repoint issued yet)"
emit_verdict H6_VIRT_JS "$h6_verdict" "$h6_evidence"

# --- Force a NEW eventN, then proxy_repoint_slot (the H5 CONFIRM check) -
if ! prompt_operator "Now force the DS4 onto a DIFFERENT eventN: replug" \
    " it into a DIFFERENT USB port, or (BT) forget/re-pair it, so the" \
    " kernel assigns a NEW event number. Press Enter once reconnected."
then
    emit_verdict H5_REPOINT OPERATOR_ABORT \
        "operator skipped the forced-renumber step"
    proxy_stop_slot "$PROXY_SLOT"
    exit 1
fi

if ! wait_for_ds4 "$RECONNECT_WAIT_S"; then
    emit_verdict H5_REPOINT FAIL \
        "DS4 did not reappear within ${RECONNECT_WAIT_S}s after the" \
        " forced renumber"
    proxy_stop_slot "$PROXY_SLOT"
    exit 1
fi

ds4_new="" ev_new=""
ds4_new=$(find_ds4_event_node)
ev_new="${ds4_new%% *}"
echo "[probe] new physical node: event${ev_new} (was event${ev_orig})" >&2
if [[ "$ev_new" == "$ev_orig" ]]; then
    echo "[probe] WARN: eventN did not actually change (${ev_new}) —" \
         "H5 will still exercise proxy_repoint_slot, but the" \
         "evidence string notes this was NOT a true renumber" >&2
fi

repoint_rc=0
proxy_repoint_slot "$PROXY_SLOT" "/dev/input/event${ev_new}" || repoint_rc=$?
if (( repoint_rc == 2 )); then
    emit_verdict H5_REPOINT FAIL \
        "proxy_repoint_slot: MCSS_EVSIEVE_BIN unavailable"
    proxy_stop_slot "$PROXY_SLOT"
    exit 1
elif (( repoint_rc == 1 )); then
    emit_verdict H5_REPOINT FAIL \
        "proxy_repoint_slot reported the slot's evsieve as dead" \
        " (link repointed, but no live process to resume forwarding)"
    proxy_stop_slot "$PROXY_SLOT"
    exit 1
fi

announce_wiggle "Wiggle the LEFT stick — we read the repointed virtual" \
    "(${virt_js}) to see whether forwarding resumed."
tally=$(capture_stream "$virt_ev" "$CAPTURE_SECONDS" post-repoint)

h5_verdict="SILENT"
if ! _tally_is_empty "$tally"; then
    h5_verdict="RESUMES"
fi
h5_evidence="repointed pads-link to event${ev_new} (was event${ev_orig});"
h5_evidence+=" virtual=${virt_ev} tally[${tally}] over"
h5_evidence+=" ${CAPTURE_SECONDS}s; renumber_confirmed="
h5_evidence+="$([[ "$ev_new" != "$ev_orig" ]] && echo yes || echo no)"
emit_verdict H5_REPOINT "$h5_verdict" "$h5_evidence"

# --- H7: teardown must leave no process, no dangling links -------------
proxy_stop_slot "$PROXY_SLOT"
sleep 0.3

h7_evidence="pads_link=$([[ -e "${MCSS_PROXY_PADS_DIR}/slot${PROXY_SLOT}" \
    ]] && echo present || echo absent)"
h7_evidence+=" virt_link=$([[ -e "${MCSS_PROXY_VIRT_DIR}/slot${PROXY_SLOT}" \
    ]] && echo present || echo absent)"
h7_evidence+=" evsieve_dead=$(_confirm_proxy_dead "$PROXY_SLOT" \
    && echo yes || echo no)"

h7_verdict="CLEAN"
if [[ -e "${MCSS_PROXY_PADS_DIR}/slot${PROXY_SLOT}" \
    || -e "${MCSS_PROXY_VIRT_DIR}/slot${PROXY_SLOT}" ]] \
    || ! _confirm_proxy_dead "$PROXY_SLOT"
then
    h7_verdict="DIRTY"
fi
emit_verdict H7_TEARDOWN "$h7_verdict" "$h7_evidence"

_stop_watchers

echo
echo "=============================================================="
echo " Results file: ${RESULTS}"
echo " evsieve log: $(_evsieve_logfile "MCSS-slot${PROXY_SLOT}")"
echo " Physical-node watcher log: $(_nodewatch_logfile)"
echo " Paste the VERDICT lines above into issue #38."
echo "=============================================================="
