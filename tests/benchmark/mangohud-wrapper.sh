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
# - Each slot has a PRIVATE tmpfs /tmp — the log output_folder MUST be under
#   $HOME or the CSVs vanish with the sandbox.
# - MANGOHUD_DLSYM=1: Minecraft/LWJGL is OpenGL; MangoHud's GL hook needs the
#   dlsym interposer (the default Vulkan layer path never engages).
# =============================================================================

export MANGOHUD_DLSYM=1
# Custom layout: the log-active red dot anchors at the overlay's corner and
# obscured the fps digits in both fps_only layouts (2026-07-17/18 runs). With
# legacy_layout=false the first element renders at the corner — a sacrificial
# BENCH label absorbs the dot and the fps row below it stays readable.
export MANGOHUD_CONFIG="${MCSS_BENCH_MANGOHUD_CONFIG:-legacy_layout=false,custom_text=BENCH,fps,position=top-right,font_size=24,output_folder=$HOME/mcss-benchmark/mangohud,log_interval=100,autostart_log=15,log_duration=1200}"

mkdir -p "$HOME/mcss-benchmark/mangohud" 2>/dev/null || true

if command -v mangohud >/dev/null 2>&1; then
    exec mangohud "$@"
fi
exec "$@"
