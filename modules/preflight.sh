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
#   mcss_notify_user <title> <body> [secs] -> 0 if a notifier was shown, 1 if none
#
# Globals CONSUMED (set elsewhere, read here):
#   LOG — launcher entry script; appended with a HARD STOP line if set
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.2 2026-07-29  #125: mcss_notify_user — the ONE encoding of "tell the
#                    user something when there is no terminal to print to"
#   v1.1 2026-07-01  v1.1 batch: env-guard + audit fixes bundled with 14
#                    other issues (no preflight-specific behavior change)
#   v1.0 2026-06-23  Initial: distro-aware hints, dual install/launch gate
# =============================================================================

# mcss_notify_user: best-effort, NON-BLOCKING, user-visible message.
#
# Fix #125: the Game Mode and nested-session paths have NO terminal, so an abort
# that only writes to a log reads to the user as a crash. Three copies of the
# kdialog→zenity ladder had grown by the time #125 needed a fourth (preflight's
# own launch popup, minecraftSplitscreen's bare-invocation refusal, and the
# no-controller abort) — this is the single encoding (PRINCIPLES #9).
#
# Lives in preflight.sh because it is the first runtime module sourced (see
# modules/runtime_modules.list) and because "tell the user why the launch cannot
# proceed" is already this module's job. utilities.sh — the installer's UX home —
# is not deployed at runtime.
#
# NEVER blocks the caller: the dialog is always backgrounded. When `secs` is given,
# a reaper self-dismisses it by killing ONLY the PID we started (PRINCIPLES #7),
# which matters for #125 specifically — a user with no controller connected may
# have no way to dismiss a modal dialog, so an undismissable one would be an
# unbounded wait (PRINCIPLES #6).
#
# Uses a real dialog window rather than kdialog --passivepopup / notify-send on
# purpose: passive popups need a notification daemon, and the host Game Mode
# context (gamescope, no Plasma shell) has none — a passive popup would silently
# show nothing there, which is the exact failure this function exists to fix.
#
# Fail open (PRINCIPLES #5): with no notifier installed the message still reaches
# stderr and the caller proceeds. A missing kdialog must never fail a launch.
#
# Inputs:
#   $1 — title
#   $2 — body (may contain newlines)
#   $3 — seconds after which to self-dismiss; omit/0 to leave it up until dismissed
# Outputs:
#   stderr — the message, always, so the debug log keeps the diagnostic
#   side effects — backgrounds a dialog (and, with $3, a reaper for it); writes
#     NOTHING to stdout (callers' stdout is captured)
#   return — 0 if a notifier was launched, 1 if none is installed
mcss_notify_user() {
    local title="$1" body="$2" secs="${3:-0}" pid=""
    echo "[notify] ${title}: ${body//$'\n'/ }" >&2
    # The notifier's OWN stderr goes to the debug log, not /dev/null: a dialog that
    # fails to reach a display ("cannot connect to display", missing Wayland socket)
    # is precisely the failure this function exists to prevent, and swallowing it
    # made the first on-Deck test of #125 undiagnosable. A FILE, never the inherited
    # stderr — a backgrounded child holding a capture pipe is what hung CI in
    # #80/#103 and #133 (PRINCIPLES #8).
    local _nlog="${SPLITSCREEN_DEBUG_LOG:-${LOG:-/dev/null}}"
    # Inside the nested session, force the dialog onto XWayland ($DISPLAY) instead
    # of letting Qt/GTK pick the native Wayland backend.
    #
    # Measured on-Deck 2026-07-29 (#125): a Wayland-native kdialog ran for its full
    # 7.76s with no error and was NEVER VISIBLE. gamescope presents the focused game
    # surface, and the Minecraft instances that DO reach the screen are XWayland
    # clients on the nested :2 display — so XWayland is the only channel proven to be
    # presented. Matching it is the point; do not "simplify" this away.
    # MCSS_NESTED_SESSION is NOT a boolean: it is "0" in the host and a session
    # TYPE inside ours ("plasma" from minecraftSplitscreen.sh:264, "kwin" for the
    # test path, with "1" also accepted per runtime_context.sh:27). Test it the way
    # minecraftSplitscreen.sh:1144 does — `!= "0"`. An earlier draft compared
    # `== "1"`, so on-Deck the branch silently never fired ([[ plasma == 1 ]]).
    local -a _env=()
    if [[ "${MCSS_NESTED_SESSION:-0}" != "0" && -n "${DISPLAY:-}" ]]; then
        _env=(env "QT_QPA_PLATFORM=xcb" "GDK_BACKEND=x11" "DISPLAY=$DISPLAY")
    fi
    if command -v kdialog >/dev/null 2>&1; then
        "${_env[@]}" kdialog --title "$title" --error "$body" >/dev/null 2>>"$_nlog" &
        pid=$!
    elif command -v zenity >/dev/null 2>&1; then
        "${_env[@]}" zenity --error --title="$title" --text="$body" >/dev/null 2>>"$_nlog" &
        pid=$!
    else
        return 1
    fi
    if (( secs > 0 )); then
        # Redirected off any capture pipe — an orphaned child holding stdout is
        # what hung CI twice before (PRINCIPLES #8).
        ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    fi
    return 0
}

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
    # No self-dismiss: this is a hard stop the user should read at their own pace.
    if [[ "$ctx" == "launch" ]]; then
        mcss_notify_user "Minecraft Splitscreen" \
            "${m1}"$'\n\n'"${m2}"$'\n\n'"See the README → Supported platforms."
    fi
    return 1
}
