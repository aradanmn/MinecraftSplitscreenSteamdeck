#!/bin/bash
# =============================================================================
# preflight.sh — fail-fast dependency + platform (KDE/gamescope) HARD STOP
# =============================================================================
# The splitscreen windowing REQUIRES KDE Plasma + KWin (and gamescope for the Game
# Mode / Steam-launched path). These are NOT universal across distros, so a missing
# piece must fail fast with a clear, distro-aware message rather than crash mid-run.
#
# Sourced by BOTH:
#   - the installer (install time, before downloading anything), and
#   - the launcher  (launch time, to catch drift / a copy moved to a non-KDE box).
#
# Supported targets: SteamOS/Steam Deck, Bazzite handheld/KDE, CachyOS with KDE +
# gamescope. NOT supported: GNOME-only / non-KDE systems (decision 2026-06-22 — we do
# NOT pursue DE-agnostic windowing).
#
# Public API:
#   _preflight_deps <install|launch>   -> 0 if OK, 1 (after printing) if a HARD STOP
# =============================================================================

# Print a package-install hint tailored to the detected distro.
_mcss_distro_hint() {
    local pkgs="$1" id=""
    [[ -r /etc/os-release ]] && id=$(. /etc/os-release 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}")
    case "$id" in
        *steamos*|*holo*)
            echo "  • SteamOS: sudo steamos-readonly disable && sudo pacman -S ${pkgs}"
            echo "            (then: sudo steamos-readonly enable)"
            ;;
        *cachy*|*arch*)
            echo "  • CachyOS/Arch: sudo pacman -S ${pkgs}"
            ;;
        *bazzite*|*fedora*)
            echo "  • Bazzite: use a KDE / handheld image — the GNOME edition is NOT supported."
            ;;
        *)
            echo "  • Install the missing package(s) with your distro's package manager: ${pkgs}"
            ;;
    esac
}

# _preflight_deps <context>: hard-stop if any critical dep / KDE-stack tool is missing.
# context = "install" or "launch" (affects the message + a best-effort GUI popup).
_preflight_deps() {
    local ctx="${1:-launch}"
    local -a missing=()
    local t

    # Critical: the launcher + nested-KWin windowing cannot function without these.
    #   jq/python3/bwrap        — state, dex X11 backend + Steam shortcut, controller sandbox
    #   dbus-run-session        — starts the nested Plasma session
    #   kwin_wayland/startplasma-wayland — the nested compositor + session
    #   xdpyinfo                — screen-resolution detection on the nested XWayland
    for t in jq python3 bwrap dbus-run-session kwin_wayland startplasma-wayland xdpyinfo; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    # qdbus (either the Qt5 or Qt6 build) — KWin scripting/reconfigure
    command -v qdbus6 >/dev/null 2>&1 || command -v qdbus >/dev/null 2>&1 || missing+=("qdbus6")

    if (( ${#missing[@]} == 0 )); then
        return 0
    fi

    local m1="Minecraft Splitscreen requires KDE Plasma + KWin (the split-screen tiling depends on them)."
    local m2="Missing required component(s): ${missing[*]}"
    {
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo " ❌ UNSUPPORTED ENVIRONMENT — cannot ${ctx}."
        echo " ${m1}"
        echo " ${m2}"
        echo ""
        echo " Supported: Steam Deck/SteamOS, Bazzite (handheld/KDE), CachyOS+KDE+gamescope."
        echo " NOT supported: GNOME-only / non-KDE systems."
        _mcss_distro_hint "${missing[*]}"
        echo "═══════════════════════════════════════════════════════════════════"
        echo ""
    } >&2
    [[ -n "${LOG:-}" ]] && echo "[preflight] HARD STOP (${ctx}): missing ${missing[*]}" >> "$LOG" 2>/dev/null || true

    # At launch (Game Mode has no terminal) try a best-effort visible popup.
    if [[ "$ctx" == "launch" ]]; then
        if command -v kdialog >/dev/null 2>&1; then
            kdialog --error "${m1}"$'\n\n'"${m2}"$'\n\n'"See the README → Supported platforms." >/dev/null 2>&1 &
        elif command -v zenity >/dev/null 2>&1; then
            zenity --error --text="${m1}"$'\n\n'"${m2}" >/dev/null 2>&1 &
        fi
    fi
    return 1
}
