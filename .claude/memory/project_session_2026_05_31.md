# Session 2026-05-31 — Controlify migration fallout fixes (hardware-confirmed)

This session fixed a chain of issues discovered after migrating from Controllable
to Controlify, all validated on a real Steam Deck (SteamOS, MC 26.1.2).

## Root causes found & fixed (all on `main`)

| Commit | Problem | Fix |
|--------|---------|-----|
| `ba8c4ec` | **Game crashed immediately** after JVM start: `NoSuchMethodError MemoryUtil.memFree(ByteBuffer)`. Backend was LWJGL 3.3.3 but MC 26.x needs 3.4.x. | `get_lwjgl_version_for_mc()` in utilities.sh now returns **3.4.1 for year≥26**, 3.4.0 for 25.x. Fallback const in lwjgl_management.sh → 3.4.1. |
| `0b18ce7` | **Steam Deck trackpad fought the joystick** — Controlify 3.x auto-input-switching jumped to keyboard+mouse on trackpad mouse events. | `writeControlifyConfig()` writes `"autoSelect": false` alongside `"currentController": "lwjgl:N"`. |
| `a5258bf`,`7d49c9e` | **cleanup script never removed the flatpak.** PrismLauncher is a **system** flatpak on Steam Deck → needs polkit password. `--noninteractive` blocked the prompt. | Detect scope via `flatpak list --user/--system`; for system scope drop `--noninteractive` so polkit can prompt. |
| `9f8dcd6` | **CI failure** — test asserted `get_lwjgl_version_for_mc 25.1 → 3.3.3`. | Updated to 25.x→3.4.0, added 26.1.2→3.4.1 case. |
| `4a1ced5` | **Desktop icon was a white paper icon.** Two bugs: `Icon="..."` was quoted (invalid per freedesktop spec → KDE can't resolve); and .ico→.png conversion only tried ImageMagick (absent on SteamOS). | Unquote `Icon=`; add Pillow + direct-PNG-download fallbacks. |
| `a2ced5a` | **Black-screen hang** (idle in `do_sys_poll`, 0% CPU, no title screen/audio). Legacy4J ships `keyboard_layout/en_us.json` (flat format); Controlify 3.x `KeyboardLayoutManager.fileToKey()` expects nested `keyboard_layout/<layout>/<lang>.json` and throws `ArrayIndexOutOfBoundsException`, blowing up the resource reload. | **Removed Legacy4J** from MODS list (install-minecraft-splitscreen.sh) + dependency map (version_management.sh). Controlify is required, so Legacy4J can never coexist. Documented "do not re-add" comments. |

## Hardware-confirmed working (2026-05-31)
- Fresh install on Steam Deck reports `Using LWJGL version: 3.4.1`, no crash.
- After removing Legacy4J jar from instances, game reaches title screen with music.
- Controller no longer fought by trackpad ("mouse no longer fighting the joysticks").

## Harmless errors seen in instance log (do NOT chase)
- `401 fetchProperties` / `Realms ... Failed to parse into SignedJWT` — offline accounts (P1–P4) can't talk to Mojang session/Realms servers. Expected, non-fatal. Would clear with real MSA login.
- `Method overwrite conflict getTexturesByName iris/factoryapi ... Skipping method` — benign mixin overlap.

## Notes / how things actually work
- Installer **always re-downloads modules from GitHub** (`BOOTSTRAP_REPO_MODULES_URL`) into a temp dir on every run. Default branch is `main`. The top-level bootstrap script is NOT auto-updated — only modules.
- FlyingEwok's fork still uses **PollyMC as a frontend** (different architecture); not relevant to our PrismLauncher-only path.
- User confirmed: push directly to `main` is fine for this work ("Main is fine, keep going").

## Still open
- **Issue #8 — Microsoft OAuth device-code flow during install** (requested, not yet built). New module `modules/account_setup.sh`. PrismLauncher client ID `c36a9fb6-4f2a-41ff-90bd-ae7cc92031eb`. Flow: devicecode → poll token → Xbox Live → XSTS → Minecraft token → entitlements/profile → write accounts.json.
- **Stale fixture**: `tests/fixtures/minecraftSplitscreen.sh` is still the old Controllable-based generated launcher. Tests pass (only syntax-validated) but it doesn't exercise the new Controlify path. Regenerate via `tools/update-fixture.sh` sometime.
- Multi-controller in-game mapping with identical models still unverified on hardware (autoSelect:false set, but per-slot lwjgl index correctness needs a real multi-pad test).
