#!/bin/bash
# =============================================================================
# mc_osk_type.sh — type text into Controlify's on-screen keyboard via gamepad
# =============================================================================
# TEST TOOLING (#70, discovered/built 2026-08-09 mid-benchmark-campaign).
# Not part of the runtime; nothing under modules/ sources this.
#
# WHY THIS EXISTS: chat-open keybinds (T, /) and raw keyboard text input are
# both silently swallowed once a gamepad is the active input device — even
# with Controlify's mixed_input/out_of_focus_input both true. Real keyboard
# events DO still reach Escape/F3 (not KeyMapping-routed), which is why those
# always worked while chat never did. Once chat is opened via a GAMEPAD
# action (e.g. a D-pad tap bound to "open chat"), Controlify shows its own
# on-screen keyboard — a clickable letter/number grid, not a real text field.
# rig_inject (tests/lib/uhid_rig.sh) can drive that grid directly: D-pad to
# move the highlight, BTN_SOUTH to select, BTN_THUMBL to toggle shift.
#
# GRID LAYOUT (0-indexed row,col; chat opens with the cursor on Shift,
# row3,col0):
#   row0: 0 1 2 3 4 5 6 7 8 9         (shifted: symbols; only '-' at col4 is
#                                       currently mapped/used here)
#   row1: q w e r t y u i o p
#   row2: / a s d f g h j k l         (shifted: '/' -> '|')
#   row3: shift z x c v b n m , space
# Button shortcuts (Controlify's own remapping, NOT the visual X/Y labels —
# confirmed live 2026-08-08/09 the labels are swapped from the evdev names):
#   BTN_START = Enter/submit, BTN_NORTH = Delete (removes from the END of
#   the string, not from the cursor), BTN_WEST = Space, BTN_THUMBL = toggle
#   Shift/Caps (also swaps the row0 digit row to symbols simultaneously —
#   confirmed a real keyboard's Shift-number-row behavior, not two separate
#   modes).
#
# KEY INSIGHT — do not relearn this: selecting ANY key while shifted
# auto-reverts to lowercase afterward, not just symbols — letters too. Never
# assume shift stays on after a select (it doesn't); the state machine below
# re-derives it from actual behavior, not from what you last requested.
#
# TIMING — do not relearn this either: a press held ~250ms straddles the
# menu's key-repeat threshold and silently double-fires (net no-op on a
# toggle button, or two grid moves per one intended move). A press held
# ~10ms can fall entirely between polling ticks and register as nothing (the
# menu appears to poll on something closer to the ~50ms game tick, not the
# uncapped render framerate). ~80ms hold / ~300ms gap between actions (500ms
# after a button press specifically) is the empirically validated safe zone.
# THIS IS THE ONLY THING YOU SHOULD NEED TO RETUNE if it ever misbehaves
# again — the `hold`/`gap` locals below, nothing else in the sequence logic.
#
# USAGE
#   source this file (needs tests/lib/uhid_rig.sh already sourced — uses
#   rig_inject), then with chat freshly opened (cursor on Shift, row3,col0):
#     mc_osk_type <pad_index> "<text>" [submit(0|1)] [start_row] [start_col]
#   start_row/start_col let you resume typing into an ALREADY-OPEN chat with
#   text still in it (closing and reopening chat preserves typed text but
#   resets the grid cursor back to Shift — the two are independent state;
#   don't assume the cursor followed the text).
#   Supported characters: a-z, A-Z, 0-9, '-', '/', space. Anything else is
#   skipped with a stderr warning (not silently dropped without a trace).
#
# Version history:
#   v1.0 2026-08-09  #70: initial working version, built and validated live
#                    driving real /tp commands for P1/P2/P3/P4 positioning.
# =============================================================================

mc_osk_type() {
  local pad="$1" text="$2" submit="${3:-0}"
  local hold=0.08 gap=0.3
  local cur_row="${4:-3}" cur_col="${5:-0}"
  local shift_on=0

  _p() { rig_inject "$pad" "press $1"; sleep "$hold"; rig_inject "$pad" "release $1"; sleep 0.5; }
  _h() { rig_inject "$pad" "hat $1"; sleep "$hold"; rig_inject "$pad" "hat RELEASED"; sleep "$gap"; }

  _goto() {
    local tr="$1" tc="$2"
    while (( cur_row > tr )); do _h UP; cur_row=$((cur_row-1)); done
    while (( cur_row < tr )); do _h DOWN; cur_row=$((cur_row+1)); done
    while (( cur_col > tc )); do _h LEFT; cur_col=$((cur_col-1)); done
    while (( cur_col < tc )); do _h RIGHT; cur_col=$((cur_col+1)); done
  }

  _shift() {
    if [[ "$1" != "$shift_on" ]]; then _p BTN_THUMBL; shift_on="$1"; fi
  }

  local i char row col want_shift
  for (( i=0; i<${#text}; i++ )); do
    char="${text:$i:1}"
    if [[ "$char" == " " ]]; then _p BTN_WEST; continue; fi
    row=""; col=""; want_shift=0
    case "$char" in
      /) row=2; col=0 ;;
      q|Q) row=1; col=0 ;; w|W) row=1; col=1 ;; e|E) row=1; col=2 ;; r|R) row=1; col=3 ;;
      t|T) row=1; col=4 ;; y|Y) row=1; col=5 ;; u|U) row=1; col=6 ;; i|I) row=1; col=7 ;;
      o|O) row=1; col=8 ;; p|P) row=1; col=9 ;;
      a|A) row=2; col=1 ;; s|S) row=2; col=2 ;; d|D) row=2; col=3 ;; f|F) row=2; col=4 ;;
      g|G) row=2; col=5 ;; h|H) row=2; col=6 ;; j|J) row=2; col=7 ;; k|K) row=2; col=8 ;;
      l|L) row=2; col=9 ;;
      z|Z) row=3; col=1 ;; x|X) row=3; col=2 ;; c|C) row=3; col=3 ;; v|V) row=3; col=4 ;;
      b|B) row=3; col=5 ;; n|N) row=3; col=6 ;; m|M) row=3; col=7 ;;
      0) row=0; col=0 ;; 1) row=0; col=1 ;; 2) row=0; col=2 ;;
      3) row=0; col=3 ;; 4) row=0; col=4 ;; 5) row=0; col=5 ;;
      6) row=0; col=6 ;; 7) row=0; col=7 ;; 8) row=0; col=8 ;;
      9) row=0; col=9 ;;
      -) row=0; col=4; want_shift=1 ;;
      *) echo "mc_osk_type: unsupported char '$char'" >&2; continue ;;
    esac
    if [[ "$char" =~ [A-Z] ]]; then want_shift=1; fi
    _shift "$want_shift"
    _goto "$row" "$col"
    _p BTN_SOUTH
    cur_row="$row"; cur_col="$col"
    # any select performed while shifted auto-reverts state to LC afterward
    if [[ "$want_shift" == "1" ]]; then shift_on=0; fi
  done

  if [[ "$submit" == "1" ]]; then _p BTN_START; fi
}
