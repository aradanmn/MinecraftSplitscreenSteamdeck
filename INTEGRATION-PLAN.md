# Integration Plan — feat/gamescope-windowing → main

_Codebase analysis 2026-06-22. Traces the real install→run flow and the work needed to land the branches on `main`._

## TL;DR

- `main` (Feb 1) is the **old static-launcher architecture** and is fully superseded — it has no `minecraftSplitscreen.sh` and no `orchestrator.sh`. Landing the new work is a **wholesale replacement**, not an incremental merge.
- **#1 blocker (functional):** the **production launch path is not wired to the windowing setup we got working.** The installed Steam shortcut runs `minecraftSplitscreen.sh launchFromPlasma`, but that case doesn't exist → falls through to `*)` → `main()` → bare orchestrator with **no nested compositor / no panel strip**. The working windowing lives only in the **test** path (`testPlasma`→`launchTestFromPlasma`). A real user launching from Steam would get no splitscreen tiling.
- The 3 hardcoded-`main` URLs are **auto-fixed by merging to main** (they then point at the correct code).
- `feat/gamescope-bare-kwin` is **not ready** (GL/EGL compositor blocker) — keep it separate, do not merge.
- History has **diverged** (main has 51 commits not on the branch; branch has 234 not on main) — no fast-forward; needs a deliberate merge/replace.

---

## 1. End-user flow today (install → run)

### Install — `install-minecraft-splitscreen.sh`
1. Downloads modules to a temp dir from `REPO_BASE_URL` = `…/main/modules` (or copies a local `modules/` if run from a clone).
2. Sources installer modules → `main()` in `main_workflow.sh`:
   - `ensure_bwrap_installed`, `download_prism_launcher` (PolyMC AppImage)
   - version/Java/Fabric/LWJGL detection, `configure_polymc_defaults`
   - `accounts.json` (offline P1–P4) downloaded from `…/main/`
   - mod compatibility + interactive selection
   - `create_instances` (4 instances)
   - `setup_splitscreen_launcher_script` → copies/downloads **`minecraftSplitscreen.sh`** to `~/.local/share/PolyMC/`
   - `install_runtime_modules` → deploys 7 runtime modules (dock_detection, controller_monitor, window_manager, instance_lifecycle, watchdog, orchestrator, dex)
   - `setup_steam_integration` → `add-to-steam.py` creates a Steam shortcut with **LaunchOptions = `launchFromPlasma`**
   - `create_desktop_launcher` → desktop entry `Exec=…/minecraftSplitscreen.sh`
3. Prints "Run: ~/.local/share/PolyMC/minecraftSplitscreen.sh".

### Run — dispatch in `minecraftSplitscreen.sh`
Cases that exist: `test`, `testFromPlasma|testPlasma`, `testDirect`, `testNested`, `_nestedSession`, `*`.

| Entry point | Arg | Path taken | Sets up nested compositor + windowing? |
|---|---|---|---|
| Steam shortcut (Game Mode) | `launchFromPlasma` | no match → `*)` → `main()` | **NO** ❌ |
| Desktop launcher | _(none)_ | `*)` → `main()` | **NO** ❌ |
| Test (validated working) | `test [N]` | `testPlasma` → nested Plasma + panel strip → `launchTestFromPlasma` → orchestrator + **test harness** | **YES** ✅ |

**`main()` (orchestrator.sh) only** ensures the FIFO and runs `handheld_flow`/`docked_flow`. It assumes it is already inside a working display session — it does **not** launch a nested compositor or strip the panel. Under gamescope (single-window), launching the bare orchestrator yields no tiling.

→ **The production user flow does not benefit from any of the windowing work.** This is the core integration gap.

---

## 2. Branch status

- **feat/gamescope-windowing** — new Phase-B dynamic architecture; 234 commits / 86 files ahead of main. The intended new `main`.
- **feat/gamescope-bare-kwin** — corrected `--exit-with-session` invocation (validated: session command now launches), but bare `kwin_wayland` fails to bring up its compositor under gamescope (GL/EGL: "no context is current"; no nested XWayland). **Not mergeable.** Keep for the deferred research round.

---

## 3. Integration plan

### A. BLOCKER — wire the production launch (do before merge)
Add a `launchFromPlasma` case to `minecraftSplitscreen.sh` that is the **production analog of the test path**: nested Plasma + panel strip + the **real orchestrator** (`main()` / `docked_flow` with real controller detection), instead of the test harness.
- Refactor the nested-Plasma session setup (currently inside `testPlasma`/`launchTestFromPlasma`) into a shared helper; the only difference between test and production is what runs *inside* the session (test harness vs `main()`).
- Without this, the installed Steam shortcut is non-functional for real users. This is the single most important item.

### B. Merge mechanics (history diverged)
- `main` has 51 commits not on the branch; branch has 234 not on main → **no fast-forward**.
- `main`'s tree is fully superseded (deleted files: `path_configuration.sh`, `pollymc_setup.sh`, `version_info.sh`; missing: `minecraftSplitscreen.sh`, `orchestrator.sh`). A 3-way merge would conflict heavily over obsolete files.
- **Recommended:** make the branch's tree authoritative — open a PR and merge with the branch content winning (e.g. merge `-X theirs`, or a merge commit that takes the branch tree), or reset `main` to the branch after review. Avoid hand-resolving conflicts against the dead architecture.

### C. Auto-resolved by the merge (verify after)
The hardcoded-`main` references become correct once the branch *is* main:
- `install-minecraft-splitscreen.sh` `REPO_BASE_URL`
- `launcher_setup.sh` `remote_script` (minecraftSplitscreen.sh) and `base_url` (runtime modules)
- `main_workflow.sh` `accounts.json` URL; `steam_integration.sh` `add-to-steam.py` URL
- Action: just re-verify a clean `curl | bash` install from main post-merge.

### D. Cleanup (do with the merge)
- **Delete dead code:** `modules/launcher_script_generator.sh` (unused — old generator; its functions are called nowhere), `modules/gamescope_windowing.sh`, `modules/tinywm.py`, `modules/gamescope_window_control.py` (abandoned TinyWM/gamescope-windowing approaches; not deployed by the installer).
- **Delete/relocate stale docs:** `DECISION_NEEDED.md`, `GAMESCOPE_INVESTIGATION.md`, `GAMESCOPE_RESEARCH.md` (untracked), and the pile of `SESSION-*.md` / `RAW-SESSION-*.md` (move to `sessions/`).

### E. Known functional issues at merge time (decide fix-before vs document-and-follow-up)
- **2-player tiling works.** **3–4 player has the wrong-WID re-tile bug** (Issue A): we move a window that isn't the slot's visible surface; needs a live `xwininfo -tree` capture + fix to `_poll_for_window` WID selection.
- **Teardown timing** >30s on cleanup (bump the assertion window / speed teardown).
- **Issue B:** nested-Plasma session exits cleanly but gamescope keeps its overlay (game-end detection). `--exit-with-session` (bare-kwin) would help but bare-kwin is blocked.
- Recommendation: it's reasonable to merge with these documented as known issues **once item A is done**, since 2-player works end-to-end; or hold for Issue A if 3–4 player is a launch requirement.

### F. Deferred / optional
- Installer: deploy `tests/` to the device (for on-device testing).
- Rename `minecraftSplitscreen.sh` → `mcss.sh` (cascades to `launcher_setup.sh`, `desktop_launcher.sh`, `add-to-steam.py`, and the soon-deleted generator).
- bare-KWin research round (kwin_wayland_wrapper vs raw kwin; `KWIN_COMPOSE=Q`; EGL platform env).

### G. Runtime dependency preflight (do with the merge)
The launcher's external-binary dependencies are **assumed present** — the installer only ensures `bwrap`. There is **no preflight**, so a missing tool (e.g. `jq`, `python3`) crashes the launcher mid-run with a cryptic error. Add a fail-fast preflight (see §4 for the dependency map):
- Run it **at install time** (in `main_workflow.sh`, near `ensure_bwrap_installed`) so the user is warned before they finish, and
- Guard it **at launch time** (top of `minecraftSplitscreen.sh`) to catch image drift.
- On SteamOS the rootfs is read-only, so the preflight mostly **verifies + prints a clear message** (and how to install) rather than auto-installing; it may attempt `pacman` for installable ones like `bwrap` does.

---

## 4. Runtime dependencies (mcss.sh)

| Category | Items | Status |
|---|---|---|
| **Bundled** (deployed by installer) | 7 runtime modules: `dock_detection, controller_monitor, window_manager, instance_lifecycle, watchdog, orchestrator, dex` | ✅ deployed; self-contained (no calls into installer-only modules) |
| **Critical external bins** | `jq` (all state I/O), `python3` (dex backend + placeholders), `bwrap`, `dbus-run-session` | ⚠️ only `bwrap` ensured; rest assumed |
| **KDE/session stack** | `kwin_wayland`, `startplasma-wayland`, `plasmashell`, `kscreen-doctor`, `qdbus`/`qdbus6`, `kde-inhibit` | ⚠️ assumed present (ships with SteamOS desktop) |
| **X tools** | `xdpyinfo`, `xrandr`, `xauth` | ⚠️ assumed present |
| **Fallback-only (not critical)** | `xdotool` (dex ctypes is primary), `wlr-randr` (absent on Deck; has fallback) | ok — guarded by fallbacks |
| **Generated on the fly** (NOT installed, by design) | `/tmp/dex_$$.py` (X11 backend), `/tmp/kwin_wayland_wrapper`, tkinter/xterm placeholders, `splitscreen.properties` (per instance/layout), `splitscreen_state.json`, the FIFO, `~/.config/autostart/*.desktop` | ✅ created at run time |
| **Data/assets** | 4 instances, `accounts.json`, `PolyMC.AppImage`, `polymc.cfg`, mods | ✅ installed |

### Preflight sketch
```bash
# Verify required tools; fail fast with a clear message instead of a cryptic
# mid-launch crash. Critical = launcher cannot function; session = nested-Plasma
# windowing. (xdotool/wlr-randr are intentionally omitted — fallback-only.)
_preflight_deps() {
    local missing=()
    for bin in jq python3 bwrap dbus-run-session \
               kwin_wayland startplasma-wayland kscreen-doctor xdpyinfo; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if (( ${#missing[@]} )); then
        echo "[mcss] Missing required tools: ${missing[*]}" >&2
        echo "[mcss] SteamOS: sudo steamos-readonly disable && sudo pacman -S <pkg>; then retry." >&2
        return 1
    fi
    return 0
}
```
Most of these ship with a stock SteamOS desktop, so the practical value is a clear diagnostic on a non-standard image and an explicit, documented requirement set.

---

## Suggested order
1. **A** — wire `launchFromPlasma` to the nested-Plasma+windowing path (production). Test it in Game Mode.
2. **G** — add the runtime dependency preflight (install-time + launch-time). Cheap, high-value safety net.
3. (Optional) **E/Issue A** — fix 3–4 player re-tile if needed for launch.
4. **D** — delete dead code + stale docs.
5. **B** — PR/merge the branch as the new main (branch tree wins).
6. **C** — verify a clean install from main.
7. **F** — deferred niceties + bare-KWin research later.
