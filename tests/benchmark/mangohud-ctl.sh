#!/bin/bash
# =============================================================================
# MangoHud enable/disable/status/probe-check for the benchmark run.
# =============================================================================
# Toggles per-instance MangoHud injection by editing PolyMC instance.cfg:
#   enable  → OverrideCommands=true  + WrapperCommand=<abs mangohud-wrapper.sh>
#   disable → OverrideCommands=false + WrapperCommand line removed
#
# Usage:
#   mangohud-ctl.sh enable  [slot…|all]     default: all
#   mangohud-ctl.sh disable [slot…|all]
#   mangohud-ctl.sh status
#   mangohud-ctl.sh probe-check <since-epoch>
#       After a probe run (RUNBOOK step): verify a MangoHud CSV newer than
#       <since-epoch> exists under ~/mcss-benchmark/mangohud with >10 numeric
#       fps rows → prints PROBE PASS / PROBE FAIL (exit 0/1).
#
# Env: MCSS_LAUNCHER_ROOT (default ~/.local/share/PolyMC)
#
# Self-contained on purpose — does NOT source modules/ (the baseline install's
# modules may be older). The set/replace edit mirrors setInstanceCfgValue in
# modules/instance_lifecycle.sh; keep the two in sync if the cfg format changes.
# =============================================================================
set -euo pipefail

LAUNCHER_ROOT="${MCSS_LAUNCHER_ROOT:-$HOME/.local/share/PolyMC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
WRAPPER="$SCRIPT_DIR/mangohud-wrapper.sh"
MANGOHUD_LOG_DIR="$HOME/mcss-benchmark/mangohud"
INSTANCE_PREFIX="latestUpdate-"

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
    exit 2
}

# Mirrors setInstanceCfgValue (modules/instance_lifecycle.sh) — set or replace
# a key=value line.
_set_cfg() {
    local cfg="$1" key="$2" value="$3"
    local escaped
    escaped=$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')
    if grep -q "^${key}=" "$cfg" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${escaped}|" "$cfg"
    else
        printf '%s=%s\n' "$key" "$value" >> "$cfg"
    fi
}

_slots_from_args() {
    if [[ $# -eq 0 || "${1:-}" == "all" ]]; then
        echo "1 2 3 4"
    else
        echo "$@"
    fi
}

_cfg_path() {
    echo "$LAUNCHER_ROOT/instances/${INSTANCE_PREFIX}${1}/instance.cfg"
}

cmd_enable() {
    local slot cfg
    for slot in $(_slots_from_args "$@"); do
        cfg=$(_cfg_path "$slot")
        if [[ ! -f "$cfg" ]]; then
            echo "[mangohud-ctl] slot $slot: no instance.cfg at $cfg — skipped" >&2
            continue
        fi
        _set_cfg "$cfg" "OverrideCommands" "true"
        _set_cfg "$cfg" "WrapperCommand" "$WRAPPER"
        echo "[mangohud-ctl] slot $slot: MangoHud wrapper ENABLED"
    done
}

cmd_disable() {
    local slot cfg
    for slot in $(_slots_from_args "$@"); do
        cfg=$(_cfg_path "$slot")
        [[ -f "$cfg" ]] || continue
        _set_cfg "$cfg" "OverrideCommands" "false"
        sed -i '/^WrapperCommand=/d' "$cfg"
        echo "[mangohud-ctl] slot $slot: MangoHud wrapper DISABLED"
    done
}

cmd_status() {
    local slot cfg oc wc
    for slot in 1 2 3 4; do
        cfg=$(_cfg_path "$slot")
        if [[ ! -f "$cfg" ]]; then
            echo "slot $slot: <no instance.cfg>"
            continue
        fi
        oc=$(grep '^OverrideCommands=' "$cfg" | cut -d= -f2- || true)
        wc=$(grep '^WrapperCommand=' "$cfg" | cut -d= -f2- || true)
        echo "slot $slot: OverrideCommands=${oc:-<unset>} WrapperCommand=${wc:-<unset>}"
    done
    command -v mangohud >/dev/null 2>&1 \
        && echo "mangohud binary: $(command -v mangohud)" \
        || echo "mangohud binary: NOT FOUND (wrapper will fail-open, F3-only path)"
}

cmd_probe_check() {
    local since="${1:?probe-check requires <since-epoch>}"
    [[ "$since" =~ ^[0-9]+$ ]] || { echo "[mangohud-ctl] since-epoch must be numeric" >&2; exit 2; }
    local f mt best="" best_rows=0
    for f in "$MANGOHUD_LOG_DIR"/*.csv; do
        [[ -f "$f" ]] || continue
        mt=$(stat -c %Y "$f" 2>/dev/null) || continue
        (( mt >= since )) || continue
        # Count numeric fps rows using the same dynamic-column logic as
        # summarize.sh
        local rows
        rows=$(awk -F, '
            hdr == 0 { for (i = 1; i <= NF; i++) if ($i == "fps") { col = i; hdr = 1 }; next }
            hdr == 1 && $col + 0 > 0 { n++ }
            END { print n + 0 }' "$f")
        if (( rows > best_rows )); then
            best="$f"; best_rows=$rows
        fi
    done
    if (( best_rows > 10 )); then
        echo "PROBE PASS — $best ($best_rows fps samples)"
        exit 0
    fi
    echo "PROBE FAIL — no MangoHud CSV newer than $(date -d "@$since" 2>/dev/null || echo "$since") with >10 fps samples in $MANGOHUD_LOG_DIR"
    exit 1
}

case "${1:-}" in
    enable)       shift; cmd_enable "$@" ;;
    disable)      shift; cmd_disable "$@" ;;
    status)       cmd_status ;;
    probe-check)  shift; cmd_probe_check "$@" ;;
    *)            usage ;;
esac
