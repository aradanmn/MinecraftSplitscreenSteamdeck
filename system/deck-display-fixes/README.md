# Deck display / suspend fixes

System-level scripts that keep the external display working through boot,
dock hotplug, and suspend/resume on a docked Steam Deck (SteamOS Game Mode).
These are **not** part of the Minecraft splitscreen app — they live in
`~/.local/bin`, `~/.config/systemd/user`, and `/etc` on the Deck.

## Components

| File | Installed to | Role |
|------|--------------|------|
| `predock-probe.sh` *(pre-existing, Deck-only)* | `~/.local/bin/` | Waits for EDID before gamescope takes DRM master (boot-with-dock MST race) |
| `dock-display-hotplug.sh` | `~/.local/bin/` | udev-triggered; restarts gamescope only if MST probe failed (EDID missing). Sanitizes env first. |
| `resume-display-restore.sh` | `~/.local/bin/` | Oneshot worker: sanitize env → nudge gamescope if docked |
| `resume-display-restore.service` | `~/.config/systemd/user/` | Oneshot unit for the worker |
| `deck-display-resume.sh` | `/etc/systemd/system-sleep/` | Robust resume trigger (invoked by systemd-sleep) |

## The WAYLAND_DISPLAY crash loop (why env-sanitize exists)

A stale `WAYLAND_DISPLAY=wayland-1` left in the `systemd --user` environment
(e.g. by a nested compositor) makes the embedded gamescope select the *nested*
backend, fail to connect to a non-existent parent socket, and crash-loop —
both screens black, unrecoverable. `start-gamescope-session` clears
`DISPLAY`/`XAUTHORITY` but not `WAYLAND_DISPLAY`, and a `systemctl --user
restart gamescope-session.target` bypasses it. So every restart path here
clears `WAYLAND_DISPLAY DISPLAY XAUTHORITY` first.
Reported upstream: ValveSoftware/SteamOS#2467.

## Why a system-sleep hook instead of `journalctl -f`

The old resume watcher tailed `journalctl -f -k` for `PM: suspend exit`. That
process gets frozen during suspend and can miss the resume event. SteamOS 3.8.x
uses `systemd-suspend.service`/`systemd-sleep` (it ships its own hooks in
`/usr/lib/systemd/system-sleep/`), so an `/etc/systemd/system-sleep/` hook is
invoked *by* the resume sequence and cannot be missed.

## Install

```sh
cd system/deck-display-fixes && ./install.sh
```

## Test without restarting gamescope

```sh
RESUME_RESTORE_DRYRUN=1 ~/.local/bin/resume-display-restore.sh
cat /tmp/resume-display-restore.log
```
