---
name: SDL Isolation via WrapperCommand
description: Why --no-single-instance was removed and how SDL_JOYSTICK_DEVICE isolation was moved to WrapperCommand shell scripts
type: project
---

## Problem (prior session, carried over)
- `--no-single-instance` was added to bypass PrismLauncher IPC, but it made PrismLauncher start a fresh GUI and silently ignore the `-l` instance-launch argument — Minecraft never started for any player.
- `SDL_JOYSTICK_DEVICE` was written to `instance.cfg` `Env=` field. PrismLauncher caches all configs in memory at startup (0.063s in logs, lines 87-90). Writes to `instance.cfg` after startup are never re-read. SDL env was silently discarded for Player 2.

## Solution Implemented (commit 28403d9, 2026-03-15)
**`WrapperCommand` per-slot shell scripts** — PrismLauncher caches the wrapper *path* at startup (constant), but executes the wrapper *content* at launch time (not cached). Content can be rewritten between launches.

### New functions in launcher script
- `initSdlWrappers()` — creates `INSTANCES_DIR/latestUpdate-N/sdl-wrapper.sh` passthrough, sets `WrapperCommand=` + `OverrideCommands=true` in each `instance.cfg` at session start (before first PrismLauncher launch so path is in its cache)
- `writeInstanceSdlEnv(slot, dev)` — writes `export SDL_JOYSTICK_DEVICE="$dev"; export SDL_JOYSTICK_HIDAPI=0; exec "$@"` to the wrapper before launching that slot
- `clearInstanceSdlEnv(slot)` — resets wrapper to passthrough `exec "$@"` after instance stops
- `cleanupSdlWrappers()` — removes wrapper files and clears `WrapperCommand=` on exit

### Changes to launchGame()
Removed all `--env=SDL_JOYSTICK_DEVICE=` and `sdl_dev` parameter. SDL isolation is now entirely in the wrapper script, not the flatpak command line.

### IPC approach (--no-single-instance removed)
Player 1: `flatpak run org.prismlauncher.PrismLauncher -l latestUpdate-1 -a Player1` starts PrismLauncher fresh. Its wrapper PID stays alive.
Player 2+: same command delegates via IPC socket. IPC client exits in ~1-2s; wrapper PID is dead quickly. Java is found later by `pgrep`.

### Flatpak sandbox note
JavaPath in instance.cfg uses `/var/home/bazzite/.var/app/...` host path — confirmed accessible from within the flatpak sandbox. Host paths can be used in WrapperCommand without issue.

## Commits
- `be2c225` — Remove `--no-single-instance` to restore `-l` flag processing
- `28403d9` — Use WrapperCommand for SDL controller isolation
