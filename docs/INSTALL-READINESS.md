# Install readiness — stock SteamOS → installer → working splitscreen (v1 ship gate)

The runtime (launch/windowing/controllers/lifecycle) is validated on the Deck, but the
**install path a real user takes has never been run end-to-end** (SPEC D1: "code exists,
unverified"). This doc is the audit + checklist for that gate. Audited 2026-06-26.

> Branch `feat/gamescope-windowing` is the real trunk; `main` is stale and lacks the runtime.

## How a user installs (README path)
`wget …/<ref>/install-minecraft-splitscreen.sh && ./install-minecraft-splitscreen.sh`
→ single file, no local `modules/` → bootstrap **downloads** all 19 modules (10 installer +
9 runtime) from `…/<ref>/modules` → sources installer modules → `main_workflow.sh:main()`.

## Install step sequence (main_workflow.sh)
0. bootstrap: download+verify all modules (install-…sh)
1. **`_preflight_deps install`** — dependency/KDE hard-stop (now runs; see Fixed #1)
2. `download_prism_launcher` — PolyMC AppImage (GitHub API SPOF)
3. `get_minecraft_version` (Mojang + Modrinth) · `detect_java` (Temurin → ~/.local, works on read-only) · version/fabric/lwjgl
4. `accounts.json` download (warning-only if it fails)
5. mod resolve/select (required = Modrinth; CurseForge+token.enc only for optional)
6. `create_instances` (latestUpdate-1..4; Fabric; mods; options.txt) — idempotent update preserves saves+options.txt ✅
7. **`setup_splitscreen_launcher_script`** + **`install_runtime_modules`** → TARGET_DIR (now fatal on failure; see Fixed #2)
8. `setup_steam_integration` (add-to-steam.py; shortcut LaunchOptions=launchFromPlasma; restarts Steam) · `create_desktop_launcher`
9. success banner

## Blockers — status
- ✅ **FIXED — all `/main/` URLs hardcoded; runtime not on main → bootstrap 404/abort.**
  Now `${REPO_REF:-main}` across every URL + exported from the entry (commit df020a2).
  Install from a branch: `REPO_REF=feat/gamescope-windowing ./install-…sh`. (To ship from
  `main`, promote the branch.)
- ✅ **FIXED #1 — install-time preflight was a silent no-op (G1).** `preflight.sh` is now
  sourced by the installer, so `_preflight_deps install` actually hard-stops on missing
  deps (jq, python3, bwrap, dbus-run-session, kwin_wayland, startplasma-wayland, xdpyinfo,
  qdbus6) with a distro-aware message. No `sudo`/`pacman` attempted (read-only SteamOS).
- ✅ **FIXED — `ensure_bwrap_installed` tried `sudo pacman` (fails on read-only) + return
  ignored.** Removed the install attempt; bwrap is covered by the preflight hard-stop.
- ✅ **FIXED #2 — installer reported "✅ success" even when the launcher/runtime failed to
  install.** `setup_splitscreen_launcher_script` now validates the fetched file (fails on a
  404/empty/non-script), and both it and `install_runtime_modules` are fatal in main().

## THE remaining gate — needs a Deck run (audit Open Q#1)
Does **stock SteamOS Game Mode** provide `startplasma-wayland`, `kwin_wayland`,
`dbus-run-session`, `xdpyinfo`, `qdbus6`, `kde-inhibit` on PATH? The whole nested-KWin
windowing depends on it. This is the real "does it run" unknown, separate from the installer.

## Reassuring (audit-confirmed)
- Idempotent re-install preserves each instance's `saves/` + `options.txt`; no duplicate instances.
- Required mods are all Modrinth → `token.enc`/CurseForge not needed on the required path.
- Temurin install is user-home only → works on read-only SteamOS without root.

## The end-to-end test (do on a stock/clean Deck, Desktop Mode)
```
wget https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/feat/gamescope-windowing/install-minecraft-splitscreen.sh
REPO_REF=feat/gamescope-windowing ./install-minecraft-splitscreen.sh
```
Then Game Mode → launch the "Minecraft Splitscreen" shortcut → validate 1–4-player splitscreen.
Watch for: preflight passes (or hard-stops cleanly), runtime deploys, shortcut appears, and
the Game-Mode PATH question above.

## Lower-priority / non-blocking
- PolyMC is archived (releases still resolve; future SPOF; runtime already falls back to PrismLauncher).
- Steam is killed/restarted mid-install (disruptive if run from Game Mode).
- `token.enc` + hardcoded passphrase still committed (only for optional CF mods; rotate+remove).
