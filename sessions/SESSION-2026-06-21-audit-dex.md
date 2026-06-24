# Session 2026-06-21 — Re-sync, audit, verify + wire in dex.sh

## RAW TRANSCRIPT PUSH 1 — Catch up + multi-agent audit

User: "re-read the remote repo and get up to speed"
→ Found local was 5 commits BEHIND origin (a separate 2026-06-20 deepseek session
  had pushed): ddde9d2 (removed all functional xdotool from window_manager.sh →
  ctypes/dex), 5c16217 (removed DISPLAY_MODE_CHANGE injects from tests except Test
  5 — that inject made docked_flow return 1 → event loop exit → no FIFO reader →
  injects hang; the exact "FIFO not consumed" hang). Fast-forwarded to a6f5b92.
  Deck already on a6f5b92, clean.
→ Ran a 6-agent audit of the actual code. Resolved its internal contradiction by
  reading source: window_manager.sh OR-cycle SET struct is correct (1<<9, full
  layout, restype set) but its VERIFY/GET struct is missing `colormap` (which in
  real Xlib sits BETWEEN save_under and map_installed) → every later field reads
  8 bytes off → that is why the run showed OR=0 + garbage map_state (a FALSE
  NEGATIVE; OR was probably set, verify misread it). The genuinely-broken copies
  are instance_lifecycle.sh:339-414 (gamescope block: XOpenDisplay no restype →
  truncation + valuemask 1<<3) and gamescope_windowing.sh:160-189 (same).
  system/deck-display-fixes is UNTRACKED (not on remote).

User: "Deck suspend/resume is not in scope for this project, let's verify dex.sh
is working then wire it in."
→ Dropped system/ from scope.

## RAW TRANSCRIPT PUSH 2 — dex verified working + wired in

→ Verified dex.sh on the live gamescope :0 display over SSH (DISPLAY=:0,
  /run/user/1000/xauth_*):
  - dex opens the display WITHOUT segfault (the 4-bug pointer fix works)
  - dex_search --name "" → 28 window IDs (XQueryTree + _NET_WM_PID/WM_NAME reads)
  - dex_getgeometry 853 → "0 0 1920 1080" (XGetWindowAttributes struct correct)
  - dex_move_resize <wid> 700 400 500 300 → reads back EXACTLY 700 400 500 300
  - dex_move_resize_force <wid> 100 100 640 480 → EXACTLY 100 100 640 480
    (strategy 2 = override_redirect + XConfigure — the OR path works)
  Found + fixed a 5th bug: dispatch passes args to no-arg actions (root_wid,
  list) → "takes 0 positional arguments but 1 was given". The FUNCTIONAL calls
  (search/getgeometry/move) take args and were unaffected.
→ Wired dex in:
  - dex.sh: action_root_wid/action_list accept args=None; REMOVED the
    `trap _dex_cleanup EXIT` (it would clobber the orchestrator's EXIT trap —
    kwin teardown + session-env restore — reintroducing black-screen/leak bugs).
  - minecraftSplitscreen.sh: added dex.sh to the module source loop (last, so it
    doesn't change when set -euo turns on for earlier modules).
  - window_manager.sh: replaced _apply_override_redirect_cycle's inline ctypes
    (124 lines, the false-negative verify struct) with dex_set_override_redirect
    + dex_move_resize_force + dex_getgeometry. Now ONE verified X11 layer.
  Sourcing dex also revives _verify_window_geometry and _get_wid_from_state's
  dex_search fallback (they were silent no-ops because dex wasn't sourced).
→ Still TODO (flagged): instance_lifecycle.sh:339-414 and gamescope_windowing.sh
  inline ctypes copies still have the old truncation+1<<3 bugs — currently dead
  no-ops (truncated dpy → all X calls silently fail). Consolidate onto dex next.

END OF RAW TRANSCRIPT PUSH 2

## RAW TRANSCRIPT PUSH 3 — Consolidate remaining inline ctypes onto dex

User: "do 1 then I'll run the test" (consolidate the two remaining inline ctypes
copies onto dex)
→ Discovered gamescope_windowing.sh is DEAD CODE: not sourced anywhere; every
  caller guards with `command -v gamescope_windowing_apply_layout`/`type` (false
  when unloaded) and falls back to window_manager → dex. So refactoring it is
  moot. Added a prominent DEAD/UNUSED header to it instead (it still carries the
  old truncation + 1<<3 bugs; documented "port to dex if ever revived").
→ The LIVE copy was instance_lifecycle.sh::_poll_for_window. It also still had
  functional xdotool the 06-20 pass missed. Rewrote it to use dex only:
  - xdotool search --name → dex_search --name (strategy 1)
  - xdotool search --pid → dex_search --pid (strategy 2, matches _NET_WM_PID)
  - xdotool set_window --name → dex_set_name
  - REMOVED ~150 lines: both inline-ctypes OR-cycle copies (gamescope branch with
    STEAM_GAME/STEAM_OVERLAY + 1<<3 + truncation; desktop branch with 1<<3) AND
    the xdotool fallback. _poll_for_window now ONLY finds + renames the window;
    apply_layout() does positioning via dex right after. (STEAM overlay-plane
    setup dropped — it targets bare gamescope, not our nested-KWin approach.)
→ Also swapped window_manager.sh's debug window-listing from xdotool
  (`xdotool search --name "."` — a known event-loop hang risk in gamescope) to
  dex_list_windows.
→ Result: NO functional xdotool remains in any LIVE module (instance_lifecycle,
  window_manager, orchestrator) — only comments and one stale log string. dex.sh
  is the single X11 layer. All bash syntax-checked.
→ Ready for the user's full Phase B test run.

END OF RAW TRANSCRIPT PUSH 3
