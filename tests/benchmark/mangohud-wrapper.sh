#!/bin/bash
# =============================================================================
# PolyMC WrapperCommand target: run the instance's java under MangoHud.
# =============================================================================
# Installed per-instance by mangohud-ctl.sh (instance.cfg: OverrideCommands=true
# + WrapperCommand=<this file>). PolyMC invokes it as `<wrapper> java …`, so
# exec'ing "$@" runs the game unchanged.
#
# FAIL-OPEN by design: if mangohud is missing or anything here breaks, the game
# must still launch — a benchmark helper must never take down a session.
#
# Constraints (verified against modules/instance_lifecycle.sh):
# - Runs INSIDE the bwrap sandbox; / and /home are bound, so /usr/bin/mangohud
#   and this script are reachable.
# - Each slot has a PRIVATE tmpfs /tmp — the log output_folder MUST NOT be
#   under /tmp or the CSVs vanish with the sandbox. The repo checkout lives
#   under /home, which IS bound, so .workdir/ is durable and reachable (#122).
# - MANGOHUD_DLSYM=1: Minecraft/LWJGL is OpenGL; MangoHud's GL hook needs the
#   dlsym interposer (the default Vulkan layer path never engages).
# =============================================================================

export MANGOHUD_DLSYM=1

# #122: CSVs go under the repo scratch dir, not ~/mcss-benchmark.
#
# The source is GUARDED and the whole config is conditional because this file
# sits on the launch path inside the sandbox, where fail-open outranks
# benchmarking (PRINCIPLES #5): if the lib is somehow unreachable we skip the
# logging config entirely and still exec the game. Deliberately NOT duplicating
# the path expression as a fallback — a second encoding of it is exactly what
# this issue is removing.
_WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -r "$_WRAPPER_DIR/../lib/workdir.sh" ]]; then
    # shellcheck source=tests/lib/workdir.sh
    source "$_WRAPPER_DIR/../lib/workdir.sh"
    _MH_DIR="$(mcss_workdir benchmark/mangohud)"
    mcss_workdir_init benchmark/mangohud || true
    # Custom layout: the log-active red dot anchors at the overlay's corner and
    # obscured the fps digits in both fps_only layouts (2026-07-17/18 runs).
    # With legacy_layout=false the first element renders at the corner — a
    # sacrificial BENCH label absorbs the dot and the fps row stays readable.
    export MANGOHUD_CONFIG="${MCSS_BENCH_MANGOHUD_CONFIG:-legacy_layout=false,custom_text=BENCH,fps,position=top-right,font_size=24,output_folder=${_MH_DIR},log_interval=100,autostart_log=15,log_duration=14400}"
fi

if command -v mangohud >/dev/null 2>&1; then
    exec mangohud "$@"
fi
exec "$@"
