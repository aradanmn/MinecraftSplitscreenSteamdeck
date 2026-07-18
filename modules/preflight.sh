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
#
# Globals CONSUMED (set elsewhere, read here):
#   LOG — launcher entry script; appended with a HARD STOP line if set
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.1 2026-07-01  v1.1 batch: env-guard + audit fixes bundled with 14
#                    other issues (no preflight-specific behavior change)
#   v1.0 2026-06-23  Initial: distro-aware hints, dual install/launch gate
# =============================================================================

# _mcss_distro_hint: Print a package-install hint tailored to the detected
# distro (SteamOS/Holo, CachyOS/Arch, Bazzite/Fedora, else generic).
# Inputs:
#   $1 — space-separated list of missing package/tool names
# Outputs:
#   stdout — one or two hint lines
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

# _preflight_deps: Hard-stop if any critical dep / KDE-stack tool is missing.
# Inputs:
#   $1 — context: "install" or "launch" (default "launch"); affects the
#        message wording and whether a best-effort GUI popup is attempted
#   Globals: LOG (read, optional)
# Outputs:
#   stderr — diagnostic block on failure; a kdialog/zenity popup at launch
#   side effects — appends a HARD STOP line to $LOG if set
#   return — 0 if all deps present, 1 otherwise
_preflight_deps() {
    local ctx="${1:-launch}"
    local -a missing=()
    local t

    # Critical: the launcher + nested-KWin windowing cannot function without these.
    #   jq/python3/bwrap        — state, dex X11 backend + Steam shortcut, controller sandbox
    #   dbus-run-session        — starts the nested Plasma session
    #   kwin_wayland/startplasma-wayland — the nested compositor + session
    #   xdpyinfo                — screen-resolution detection on the nested XWayland
    #   kwin_wayland_wrapper     — #27: the launcher generates its OWN wrapper at
    #                              /tmp/kwin_wayland_wrapper (nestedPlasma/testPlasma/
    #                              launchFromPlasma), but that wrapper itself execs the
    #                              REAL /usr/bin/kwin_wayland_wrapper — if the system one
    #                              is missing, the nested session silently fails to start
    #                              instead of hitting this hard-stop up front.
    for t in jq python3 bwrap dbus-run-session kwin_wayland startplasma-wayland xdpyinfo \
             kwin_wayland_wrapper; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    # qdbus (either the Qt5 or Qt6 build) — KWin scripting/reconfigure
    command -v qdbus6 >/dev/null 2>&1 || command -v qdbus >/dev/null 2>&1 || missing+=("qdbus6")

    # #27: inotifywait (inotify-tools) is NOT hard-required — dock_detection.sh already
    # falls back to polling at runtime when it's absent — but its absence was previously
    # invisible until you went looking at a runtime log line. Surface it as a soft,
    # non-fatal warning here so it shows up at install/launch time instead.
    if ! command -v inotifywait >/dev/null 2>&1; then
        echo "[preflight] NOTE: inotifywait (inotify-tools) not found — dock/undock detection will use slower polling instead of instant hotplug notification. Not fatal." >&2
    fi

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
