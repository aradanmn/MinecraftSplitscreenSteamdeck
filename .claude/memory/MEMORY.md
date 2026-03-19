# Memory Index

## Project
- [Game Mode Controller Detection & Isolation](project_game_mode_controllers.md) — How Steam Input changes controller visibility in gamescope vs Desktop Mode; bugs fixed 2026-03-15; key functions and slot assignment logic
- [Codebase Analysis — Known Bugs and Dead Code](project_code_analysis.md) — Confirmed bugs, dead code, and false positives from 2026-03-15 analysis (most dead code now fixed)
- [SDL Isolation via WrapperCommand](project_sdl_wrappercommand.md) — Why --no-single-instance was removed; how SDL_JOYSTICK_DEVICE isolation moved to per-slot wrapper scripts (commits be2c225, 28403d9)
- [Dynamic Splitscreen Screen Resize & Reconnect Fixes](project_dynamic_reposition_bugs.md) — Screen not resizing on disconnect + reconnect not spawning instance; KNOWN_CONTROLLER_COUNT sync fix (commit f167cd4)
- [Session 2026-03-15 afternoon — generator fixes, dead code, README](project_session_2026_03_15b.md) — inhibitScreen back-port, 449-line dead code purge, README rewrite
- [Session 2026-03-15 evening — merge rev3 into main, resync](project_session_2026_03_15c.md) — Merged rev3 into main; resolved 3.2.x conflicts; WrapperCommand SDL reverted to instance.cfg approach; open issues #5/#6/#8/#10/#11
- [Session 2026-03-19 — Issue #10 fix, test harness, Controllable research](project_session_2026_03_19.md) — Removed KNOWN_CONTROLLER_COUNT sync; tools/test-dynamic-mode.sh for SSH testing; Controllable upstream not viable for identical-controller fix

## Feedback
- [Generated script vs generator source out of sync](feedback_generated_script.md) — Always back-port fixes to `launcher_script_generator.sh` heredoc, not just the generated script
- [Resync repo on every session start](feedback_resync_on_launch.md) — Run `git fetch origin && git pull --ff-only origin main` at the start of every conversation
