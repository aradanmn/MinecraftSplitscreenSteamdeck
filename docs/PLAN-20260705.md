# MinecraftSplitscreenSteamdeck — v1.1 Work Plan

**Date:** 2026-07-05 · **Repo:** aradanmn/MinecraftSplitscreenSteamdeck · **Baseline:** `main` @ d77c915 (tag v1.0.0), branch `claude/codebase-review-v1-1-120ktb` @ 387c7da

This plan was produced by a multi-agent deep analysis: 11 inventory agents read every module function-by-function, consolidation agents built the globals set / duplication map / style guide / release plan, and adversarial verifiers checked the globals proposal for naming collisions and completeness. **Confidence notes:** the process-boundary (scoping) verifier and the five per-duplication verifiers were cut off by a session limit; the five high-severity duplication claims were re-verified by hand against the source afterward (all confirmed), and the corrections from the two verifiers that did run are folded into Part 4. Line numbers cite `main` unless marked *(branch)*.


> **STATUS (2026-07-06):** v1.1.0 shipped (PR #63, tag `v1.1.0`) with the campaign's
> core validated on hardware — stages 0–5, R1 answered, R2 vindicated (the 60s
> supervisor wait was indeed the top regression, twice over — see #60). This
> document is now the **frozen design record**; living status moved to GitHub:
> **milestones** (`v1.1.1 — validation debt + hygiene`, `v1.2 — controller
> identity + consolidation`, `backlog`) and the **#68 umbrella issue** for the
> v1.1.1 gap campaign (unrun plan items 6/7/10/12/13 + ship-mechanics verify).
> Part 4 Group B and dup kill-list D1/D3/D5 landed early (PRs #64/#65). New
> since this plan: #61 (4-pad cascade symptom record) and #62 (sandbox input-node
> leakage — probable #61 mechanism; intersects the #38 decision).

---

## Part 1 — Codebase map (the 30-second version)

| Layer | Files | Role |
|---|---|---|
| Runtime entry | `minecraftSplitscreen.sh` (1,199 ln) | Deployed to `~/.local/share/PolyMC/`; dispatch on argv; nested-session scaffolding; legacy Phase-A test paths |
| Runtime modules | `modules/{preflight, dock_detection, controller_monitor, kwin_positioner, window_manager, instance_lifecycle, watchdog, orchestrator, dex}.sh` (+ `runtime_context.sh` on the v1.1 branch) | Sourced by the entry script inside the nested session; orchestrator's `main()` is the session loop (FIFO events: CONTROLLER_ADD/REMOVE, SLOT_DIED, DISPLAY_MODE_CHANGE) |
| Installer | `install-minecraft-splitscreen.sh` + `modules/{utilities, java_management, lwjgl_management, version_management, instance_creation, mod_management, launcher_setup, steam_integration, main_workflow, desktop_launcher}.sh` + `add-to-steam.py` | curl\|bash bootstrap → downloads modules at `REPO_REF` → PolyMC + Java + 4 instances (`latestUpdate-1..4`) + mods + Steam shortcut |
| Cross-process state | `~/.local/share/PolyMC/splitscreen_state.json` (mode + per-slot pid/bwrap_pid/event_node/js_node/wid), `/tmp/minecraft-splitscreen.fifo` | The contract between orchestrator, monitors, watchdog, window tools, and tests |
| Tests | `tests/hardware/stage0–stage5` staged on-Deck suite, plus ad-hoc probes | stage0 prereqs → stage0b install → stage1 module smoke → stage2 handheld → stage3 hotplug → stage4 isolation → stage5 crash |

Two shells styles coexist: the "new-generation" module style (boxed headers, `set -euo pipefail`, `lower_snake` + `MODULENAME_` constants) and legacy camelCase in `minecraftSplitscreen.sh`. The style guide (Part 6) canonicalizes the former.

---

## Part 2 — Deck bring-up runbook (factory-reset → testable)

1. **Network + OOBE:** Game Mode → Settings → Internet → join Wi-Fi; log into Steam; let any pending SteamOS update finish and **record the OS build number** for the test log (known baseline).
2. **Desktop Mode:** set a password in Konsole (`passwd`) — fresh Decks have none; needed for sshd/sudo.
3. **SSH** (drive tests from the workstation while the Deck is in Game Mode): `sudo systemctl enable --now sshd`; `ip -4 addr show wlan0`; `ssh-copy-id deck@<ip>`. Caveat: SSH sessions land **outside** the gamescope session — for environment-guard testing read `systemctl --user show-environment` or the launcher debug log, never trust the SSH env.
4. **No pacman.** Read-only rootfs; the product must work on stock SteamOS anyway. `git` ships with SteamOS. If `gh` is needed on-Deck, use the static tarball into `~/.local/bin` (session PATH only — don't edit `~/.profile`; that's what #41 is cleaning up). Otherwise drive GitHub from the workstation.
5. **Repo auth:** HTTPS + fine-grained PAT (scoped to this repo, revoke after the cycle) with `credential.helper store`; or zero-credential: clone from the workstation over SSH.
6. **Clone + branch:** `git clone … && git checkout claude/codebase-review-v1-1-120ktb`.
7. **Install from the branch:** run the installer with `REPO_REF=claude/codebase-review-v1-1-120ktb` (parameterizes all bootstrap URLs), or drive it via `tests/hardware/stage0b`. **After every subsequent `git pull`, redeploy** to `~/.local/share/PolyMC/` — pull-without-redeploy has produced false test results twice; verify freshness before each phase (e.g. `ls ~/.local/share/PolyMC/modules/runtime_context.sh`).
8. **Controllers:** pair the 4 external pads (DS4s are the validated set) in Desktop Mode first; confirm `ls /dev/input/js*` shows all four while docked.

---

## Part 3 — v1.1 validation campaign (you are the arbiter)

**Standing rule:** every item ends with an **owner-observable pass criterion** — "you see X on screen / you have control" — never "the log says OK." Logs are attached to issues as evidence, but closure requires the owner check.

### Scope call

- **On the branch already (validate, don't rewrite):** #42, #40, #43 (env/session half), #15/D6, #16–#19, #21–#27, #31, #32, CI, #38 probe script.
- **Add to v1.1:** #41 (the only issue actually labeled v1.1; installer-local, testable in stage0b) · #43 remainder → close the env half against the branch, split mode/screen/paths into a new issue (Part 4 is its spec) · G5 README wording · G1 record reconciliation (TODO vs INSTALL-READINESS disagree) · ship mechanics (deploy step, strip test code, tree-wins merge, post-merge curl|bash verify) · **privately:** N6/N7 /tmp hardening (falls out of Part 4's `MCSS_RUNTIME_DIR` relocation) + token rotation.
- **Slip to v1.2+:** #38 implementation (record the probe verdict in release notes only), #36, #28, #14 (keep the D-state capture checklist handy in case it fires), G4, #33 (license — v1.1 stays a personal-use release), remaining 06-27 review items (H1/H2/M1/M2/M4/M5/M7/L2-L5).

### Test sequence (ordered: cheap/automated → handheld → docked → riskiest last)

**Phase A — automated, 0 controllers**
1. `stage0` prereqs; manually confirm the branch's new preflight checks (kwin_wayland_wrapper, inotifywait — #27).
2. `stage0b` installer from the branch: launcher + **all modules including `runtime_context.sh`** land in `~/.local/share/PolyMC/modules/`; 4 instances; accounts.json is install-fatal (#31 — temporarily hide the source file, confirm hard-stop, restore). Covers G1 and #41 if done.
3. `stage1` module smoke **plus the #1 unknown, tested before anything else that depends on the guard (R1):** from inside a Game-Mode context, `echo $MCSS_ENV_CONTEXT` after sourcing `runtime_context.sh` — confirm real SteamOS reports `gamescope`.

**Phase B — handheld, undocked**
4. `stage2` on a **fresh state file** (delete `splitscreen_state.json` first — that's the #40 crash path). Owner check: game launches fullscreen, built-in controls work, audio, clean exit, no orphan bwrap.

**Phase C — docked + external display, escalating controllers**
5. `stage3` hotplug: pads one at a time, sticky slots, correct quadrants. Fold in the branch's session-loop fixes: kill -9 the controller_monitor mid-session → orchestrator notices, session stays usable (#16); splash windows land in the right quadrants (#21); rapid double-plug → no double-add (#23); unplug/replug the whole hub (#25). Also first real validation of D4 raw-bind enumeration post-deploy.
6. #32 audio: ambient/weather/hostile sounds from instance 1 only; player-relevant sounds everywhere.
7. #38 probe: `tests/probe-controller-reconnect.sh` during the docked session; unplug/replug one pad; record STABLE vs CHANGED — the verdict is a release-notes deliverable, not a fix. (R4: probe has never run; pre-check that `_map_external_player_virtuals` still exists under the raw-bind default.)
8. `stage4` isolation: wiggle each stick, watch all four quadrants — pad N moves only player N.
9. `stage5` crash: kill one instance → watchdog reaps, layout reflows; after teardown `pgrep inotifywait` is empty (#22, #26).

**Phase D — branch-specific high-risk paths, run LAST (they can wedge the session)**
10. #15 teardown, three exits from a live docked session: in-game quit / Steam Stop-Game / SIGTERM. Owner check each time: back to Game Mode UI, no black screen, `systemctl --user list-units 'app-MinecraftSplitscreen*'` empty, no `startplasma-wayland`, java, or bwrap survivors. **Soak check:** a 10+ minute session is never falsely reaped (the supervisor's 60s bounded wait is R2, the single highest regression risk).
11. #42/#43 guard in Desktop Mode: desktop shortcut and bare `./minecraftSplitscreen.sh` → clean REFUSED message, no 4-player spawn, no lingering transient unit. Then the inverse: Game-Mode launch still works.
12. #40 positive path: Desktop-Mode shortcut shows the refusal, no `_set_mode` crash on missing state.
13. Regression close-out: one full handheld `stage2` run on the same deployed tree.

### Top risks

- **R1 — the guard string-match is untested on real SteamOS.** If Game Mode doesn't put "gamescope" in the XDG vars, `mcss_require_gamescope` refuses the only supported launch path. Test first (Phase A step 3); keep a one-line escape hatch ready (`MCSS_SKIP_ENV_GUARD=1`).
- **R2 — #15 rewrote the production process topology** (supervised launch, 60s bounded wait, 8-pass kill sweep) and now coexists with the launcher's cleanup trap — two teardown authorities, ordering unverified. Hence Phase D last + the soak.
- **R3 — zero Deck validation of the whole batch**, including earlier UNTESTED-marked commits (flock state locking, cleanup trap, repaint fixes, gamescope WSI env). Change nothing between phases; keep per-phase logs so failures are attributable.
- **R5 — Bug B (#14)** can masquerade as a #15 regression: a D-state java surviving SIGKILL = Bug B; capture `/proc/<pid>/{stack,wchan,status}` immediately.
- **R6 — freeze `main` during the cycle** (merge strategy is branch-tree-wins; hotfixes to main would be silently dropped). Two audit docs share H-numbering — cite doc+ID in every issue comment.
- **R7 — token.enc + its hardcoded passphrase are in public git history** (7 copies of the passphrase in code). Rotate the CurseForge token regardless of anything else; handle privately, not in the tracker.

---

## Part 4 — The canonical globals set (issue #43 completed)

**Strategy: extend `modules/runtime_context.sh` (the v1.1 branch seed), don't add a new module.** It already owns the environment group; three additions fill the scope it declared out-of-scope:

1. **`mcss_resolve_paths()`** — idempotent one-shot; resolves and `export`s (readonly where marked) the path group.
2. **`mcss_resolve_screen()`** — refreshable (re-run on DISPLAY_MODE_CHANGE), env-override-**first** cascade, honoring a no-probe flag for the `launchNested` path (gamescope kills throwaway Wayland clients).
3. **A constants block** — with the load guard done right (see "Load-guard rule" below).

### Group A — environment & session (mostly exists on branch)

| Global | Meaning | Status / action |
|---|---|---|
| `MCSS_ENV_CONTEXT` | `gamescope\|desktop\|unknown` — the #42 guard signal | Exists on branch. **Correction from verification:** the origin context survives into the nested session only because it is **explicitly passed at the re-exec boundaries** — autostart `.desktop` processes do not inherit shell env. Add it to the canonical Exec-env list (below). |
| `MCSS_LAUNCHED_BY_STEAM` | 1 if `SteamGameId`/`SteamAppId` present | Exists on branch; also pass at re-exec boundaries. |
| `MCSS_NESTED_SESSION` | `0 \| plasma \| kwin` — inside our own nested session, and which flavor (selects teardown path: Plasma-service sweep vs `kill -TERM $PPID`) | **New default+export in runtime_context.sh** (today the branch only has Exec-line writers and `:-0` readers). Folding the "kind" into the value space avoids a second single-file global (verifier recommendation, replaces the earlier separate `MCSS_NESTED_KIND`). |
| `MCSS_MODE` | Authoritative `docked\|handheld`, in-shell mirror of state-file `.mode` | New. Resolved once in `orchestrator.sh:main()` via `get_display_mode()`; `_set_mode` stays the **single writer** of both var and state; `watch_display_mode` the only updater. Retires ≥6 independent inferences (js_node-emptiness in `spawn_instance`/`_build_bwrap_command`, hardcoded mode in 4 state initializers, XDG inference in legacy dispatch). `SPLITSCREEN_MODE` survives as pure user-override input to `get_display_mode()`. |

### Group B — paths (resolve once in `mcss_resolve_paths()`)

| Global | Value / derivation | Retires |
|---|---|---|
| `MCSS_LAUNCHER_ROOT` | `$HOME/.local/share/PolyMC` (+ flatpak/Prism probe, once) | 6+ independent derivations (instance_lifecycle, entry-script candidate lists, literals in orchestrator ×4, dex, window_manager, watchdog) |
| `MCSS_INSTANCES_DIR` | `$MCSS_LAUNCHER_ROOT/instances` (legacy `INSTANCES_DIR` honored as override) | entry-script detect + per-call re-derivation |
| `MCSS_LAUNCHER_EXEC` | `LAUNCHER_EXEC` override, else detect cascade run once — **fold in the AppRun FUSE-workaround candidate** only `utilities.sh` knows | 4 resolutions with 2 different defaults |
| `SPLITSCREEN_STATE` | **Keep the name** (cross-process contract). Default resolved exactly once; all 26 inline `${SPLITSCREEN_STATE:-…}` fallbacks become bare reads; watchdog's require-no-default inconsistency becomes moot | 12+ sites in runtime code, 26 repo-wide |
| `MCSS_STATE_LOCK` / `MCSS_STATE_LOCK_TIMEOUT_S` | `"$SPLITSCREEN_STATE.lock"` / `5` | **Verifier catch:** orchestrator.sh:92 and instance_lifecycle.sh:573 each build the lock path from their *own* state-path expansion — if those defaults drift, flock silently degrades into two locks and the H3 race returns |
| `SPLITSCREEN_FIFO` | Keep name; default once (`/tmp/minecraft-splitscreen.fifo`); `mkfifo` stays only in `orchestrator.sh:main` | 6 defaulting sites |
| `MCSS_GEOM_DIR` | Already well-named; resolve `:-/tmp/mcss-geom` once | 3 inline fallbacks |
| `MCSS_RUNTIME_DIR` (+ `MCSS_PULSE_SERVER`) | `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}`, one `id -u` per session | 4+ inline derivations; note `kwin_positioner` legitimately overwrites `XDG_RUNTIME_DIR` when importing the nested bus — `MCSS_RUNTIME_DIR` is the launch-time snapshot |
| `MCSS_KWIN_WRAPPER_PATH`, `MCSS_SESSION_ENV_BAK` | Move from world-writable `/tmp` to `$MCSS_RUNTIME_DIR/mcss/` — **closes security items N6/N7 as a side effect**. **Verifier catch:** extend the same relocation to `kwin_positioner.sh`'s generated `.js` files (lines 105, 188 — KWin *executes* those), and fix dex.sh:568's stale `/tmp/dex_backend.py` help text | 3 wrapper heredocs + `/tmp` script drops |
| `MCSS_AUTOSTART_DIR` + test/prod `.desktop` names | `~/.config/autostart/splitscreen-{test,prod}.desktop` | **Verifier catch:** 6+ literal sites (write :428/:613/:676, remove :571/:697/:781); a missed `rm` strands an autostart that relaunches the game on every Plasma login |
| `MCSS_DISPLAY` | The nested Xwayland DISPLAY, set once when the X socket is confirmed up | `launchSlot`'s `${DISPLAY:-:2}`, dex's source-time `DEX_DISPLAY` capture (latent bug: captured before the nested X exists) |
| `MCSS_SCREEN_W/H` | `mcss_resolve_screen()`: override-first, then wlr-randr → kscreen-doctor → xrandr → xdpyinfo → 1280x800; **not readonly** (hotplug) | 8+ probes incl. the 1280x**720** fallback drift in `_run_position_sweep_session` |

### Group C — constants (readonly, exported)

| Global | Value | Retires |
|---|---|---|
| `MCSS_MAX_PLAYERS` | 4 | 5 per-module constants + hardcoded `{1..4}` loops, `^[1-4]$` regex, `['1'..'4']` in dex's Python backend (pass via env/argv — Python can't source bash) |
| `MCSS_INSTANCE_PREFIX` | `latestUpdate-` (+ `mcss_instance_dir <slot>` helper) | literals in 5 files incl. pgrep/pkill process-match patterns |
| `MCSS_ACCOUNT_PREFIX` | `P` (→ `P1..P4`, the accounts.json contract) | **Verifier catch:** not derivable from the instance prefix; re-derived in instance_lifecycle ×2 + legacy paths |
| `MCSS_WINDOW_TITLE_PREFIX` | `SplitscreenP` — the join key between JVM args, dex, KWin rules, watchdog | 13 occurrences across 4 files incl. a generated-Python heredoc |
| `MCSS_STEAM_VENDOR_ID` / `MCSS_STEAM_PRODUCT_ID` | `28de` / `11ff` | controller_monitor readonly pair + instance_lifecycle's independent re-default (keep old names as aliases one release) |
| `MCSS_RAW_BINDING` | `${CONTROLLER_MONITOR_RAW_BINDING:-1}` resolved once | two modules independently default a flag that **must** agree or enumeration and sandboxing diverge |

### Installer-side (second home: the installer's globals block — two processes, two homes, documented pairing)

`TARGET_DIR` (exists; make uninstaller/`add-to-steam.py`/steam_integration derive from it instead of re-hardcoding), `MCSS_REPO_RAW_URL` beside `REPO_REF` (retires 10+ URL rebuilds), **`MODRINTH_API_BASE` / `CURSEFORGE_API_BASE` / `FABRIC_META_BASE`** (verifier catch: same duplication class, 3/2/2 modules each), `JAVA_PATH`, `MC_VERSION`/`FABRIC_VERSION`/`LWJGL_VERSION` (already single-writer; extract a shared `mc_version_classify` helper — see dup D3), `MCSS_MIN/MAX_MEM_MB` (make `configure_polymc_defaults` stop hardcoding a *different* heap policy).

### Rules that make it hold together

- **Load-guard rule (verifier catch):** never `return` from the top of runtime_context.sh on an exported flag — exported values cross exec but **functions don't**, so a guarded early-return would leave a re-exec'd child with values and no API. Always define functions unconditionally; guard only the `readonly` declarations per-variable (`[[ -v ]]`), which also kills the latent readonly-on-double-source error controller_monitor already has.
- **`mcss_exec_env_string()` — the single highest-leverage helper.** There are two kinds of process boundary: fork/background (plain `export` suffices) and the **three re-exec boundaries** (autostart Exec lines, kwin session command, dbus-run-session) where env does *not* flow. Today each Exec line hand-lists its env vars — that's the next drift point. One helper generates the canonical list (`MCSS_ENV_CONTEXT`, `MCSS_LAUNCHED_BY_STEAM`, `MCSS_NESTED_SESSION`, `MCSS_MODE`, `SPLITSCREEN_STATE`, `SPLITSCREEN_FIFO`, `SPLITSCREEN_DEBUG_LOG`, `SPLITSCREEN_TEST_OBSERVE_DELAY_S`, …).
- **Loading order:** runtime_context.sh sources **first**; `mcss_resolve_environment` + `mcss_resolve_paths` run in the prologue **before** the other modules source, so their source-time defaults read canonical values.
- **Legacy names survive one release as override inputs** (`INSTANCES_DIR`, `LAUNCHER_EXEC`, `SPLITSCREEN_MODE`, `SPLITSCREEN_SCREEN_W/H`, `N_SLOTS`, `CONTROLLER_MONITOR_*`) — consumed by the resolvers, never read downstream. Every existing test override keeps working.
- **What deliberately does NOT become a global:** module-local tunables (`ORCHESTRATOR_*_S`, `WATCHDOG_*`, `INSTANCE_LIFECYCLE_*_S`, `DOCK_DETECTION_*`) — already correct practice; the bar is **2+ independent derivations**. Dropped from the original proposal after verification: `MCSS_OBSERVE_DELAY_S` (single-file tunable; keep `SPLITSCREEN_TEST_OBSERVE_DELAY_S` and just fix the `:-12` drift at minecraftSplitscreen.sh:918) and `MCSS_VERSION/COMMIT/BUILD_DATE` (single derivation; just add readonly+export hygiene).
- **Namespace hygiene:** the `MCSS_` prefix already exists on main (`MCSS_GEOM_DIR`, `MCSS_SKIP_UNCHANGED`, `MCSS_REASSERT*`, `MCSS_MODULES` in tests). Decide: `MCSS_` = runtime_context-owned; rename window_manager's module-local `MCSS_SKIP_UNCHANGED`/`MCSS_REASSERT*` to `WINDOW_MANAGER_*` (or explicitly annotate), and have the resolver honor tests' `MCSS_MODULES` as the modules-dir override.

---

## Part 5 — Duplication kill-list

All HIGH items hand-verified against source. Each becomes one GitHub issue; fixes reference `# Fix #N:` at the site.

### High severity (drift already happened or directly bug-producing)

| # | Duplication | Sites | The drift |
|---|---|---|---|
| D1 | Initial state-JSON written by two divergent initializers | minecraftSplitscreen.sh:726/869/912 (`"mode":"docked"`, byte-identical ×3) vs instance_lifecycle.sh:93 (`mode:"handheld"`) | **Already drifted on the mode field**; whichever initializer runs last silently decides session mode. Fix: `_ensure_state_file` becomes the single initializer, mode as parameter defaulting via `get_display_mode()` |
| D2 | CurseForge token download + OpenSSL decrypt copy-pasted 7× (passphrase hardcoded each time) | mod_management.sh ×6, version_management.sh ×1 | Timeouts already drifted (`timeout 10 curl` vs plain curl vs wget); all fail soft, so a missed edit surfaces as "mods mysteriously incompatible." Fix: route all sites through the existing `get_curseforge_api_token()`; move it to utilities.sh. (Token rotation itself = private security item R7) |
| D3 | MC-version → Java-major table verbatim ×4 in one function; companion `java -version` grep case ×3 | java_management.sh:27-35/47-55/67-75/89-97 (verified identical) | **Latent bug:** lwjgl/version modules handle the 26.x yearly scheme; all four Java-table copies match only `1.x` → a 26.x game falls through to Java 8 when the Mojang API is unreachable. Fix: one `_mc_version_to_java_major()` + shared `mc_version_classify` |
| D4 | Runtime 9-module manifest in three places | minecraftSplitscreen.sh:53, launcher_setup.sh:143-149, installer:98-105 | A 10th module added to 2 of 3 lists = silent feature loss (modules source "if present"). Fix: one manifest (file or shared array) read by all three |
| D5 | `SPLITSCREEN_STATE` default re-derived 12+ sites (26 repo-wide), watchdog hard-requires with no default | orchestrator ×4, window_manager ×2, dex, instance_lifecycle, minecraftSplitscreen ×4, watchdog | Lost export ⇒ everything else agrees on the fallback while watchdog errors out and slot-death detection silently disappears. Fix: Part 4 Group B |

### Medium severity (fix opportunistically, several fall out of Part 4 for free)

- **D6** FIFO default ×6 → global (Part 4). **D7** screen-probe ×8 with 800-vs-720 fallback drift → `mcss_resolve_screen()`. **D8** `mmc-pack.json` heredoc ×3 in instance_creation (create/install/update paths — split-brain on upgrade) → one `write_mmc_pack_json()`. **D9** nested-Plasma scaffolding ×3 (the launchFromPlasma header literally says "DRY in a later cleanup") → one `_start_nested_plasma <exec_cmd> <desktop_name>`. **D10** two parallel bwrap builders (launchSlot's comment pins it to a **2-week-old commit** of the module builder; the module has since gained udev blanking, steam.pipe masking, per-slot SDL flags — the static test path validates a *different sandbox* than production) → launchSlot calls `_build_bwrap_command`. **D11** state-schema knowledge ×3 (watchdog raw jq vs instance_lifecycle accessors vs orchestrator ad-hoc queries) → everyone consumes the accessors (+ generic `_get_slot_field`). **D12** slot-WID lookup in both dex and window_manager (one has a title-search fallback, one doesn't — same call, different answers) → keep one. **D13** `/proc/bus/input/devices` block parser ×5 (4 in controller_monitor + `_vendor_of_js_node`) → one keyed-record parser as public API. **D14** curl-vs-wget dance ~20× with drifting timeouts → one `fetch_url` in utilities.sh. **D15** GitHub raw URL rebuilt in 6 files → `MCSS_REPO_RAW_URL`. **D16** PolyMC root hardcoded in installer/uninstaller/add-to-steam.py/3 runtime spots (uninstaller can't see a relocated install; Python gets it via argv/env). **D17** display-detection parsing duplicated between dock_detection and window_manager (kscreen-doctor format change already bit dock_detection once, via H14) → shared display-query helper.

### Low severity (batch into one cleanup issue)

KWin one-shot script lifecycle ×2 in kwin_positioner; window-title constant scatter (subsumed by `MCSS_WINDOW_TITLE_PREFIX`); uninstaller's standalone `print_*` copies (accept as intentional, note it).

---

## Part 6 — Style guide

The full style guide is a standalone living document: **[docs/STYLE-GUIDE.md](STYLE-GUIDE.md)**. Summary of what it mandates: module headers (description, Public API, globals PROVIDED/CONSUMED, inputs/outputs, ≤6-line version history), function headers (purpose, inputs incl. globals, stdout/return/side-effect contract), one-sentence block comments, `# Fix #N:` issue references (security items never referenced in code), naming table (`MCSS_` = runtime_context-owned cross-module globals), and bash rules (`set -euo pipefail`, quoting, `local`, shellcheck gate).

---

## Part 7 — Process: tracking, history, security

- **GitHub issues are the single tracker** for everything except security. The existing label taxonomy (bug/cleanup/audit/flow-gap/v1.1/v1-blocker) is good; add labels `v1.2` and `refactor`. Every code fix cites its issue in a comment at the change site (§6.4); every issue closure cites the commit and the **owner check** that validated it on the Deck.
- **Security items** (currently: N6 /tmp TOCTOU — fixed structurally by Part 4's relocation; N7 env injection; token.enc + hardcoded passphrase in public history): tracked privately (a local SECURITY-TODO outside the repo, or GitHub private vulnerability reporting), fixed with neutral commit messages, token rotated regardless.
- **Version history** lives in git + the 6-line module-header changelog (§6.5). Tag releases (`v1.1.0`); the CI release workflow on the branch already scaffolds this.
- **Testing doctrine** (your standing rule, now written down): every fix ships with an owner-runnable on-Deck check; logs are evidence, never closure. `UNTESTED` markers stay in code until a Deck pass converts them to `VALIDATED <date>`.
- **Deploy discipline:** `git pull` ≠ deployed. Add a `deploy.sh` (rsync clone → `~/.local/share/PolyMC/`) in the v1.1 ship-mechanics batch; verify freshness before every test phase.

---

## Part 8 — Sequenced roadmap

**Recommended order — validate before refactoring.** The globals *design* (Part 4) is done on paper, but landing it before the branch is Deck-validated would invalidate the only tested tree and make failures unattributable (R3). So:

| Milestone | Content | Exit criterion |
|---|---|---|
| **M0 — Deck bring-up** (Part 2) | Network, SSH, PAT, clone, branch install | stage0/stage0b green; `MCSS_ENV_CONTEXT` probe answered (R1) |
| **M1 — v1.1 validation + ship** (Part 3) | Phases A–D; #41; G5/G1; ship mechanics; #38 probe verdict; private N6/N7-or-defer + token rotation | All owner checks pass → merge (tree-wins), tag v1.1.0, post-merge curl\|bash verified on Deck |
| **M2 — globals consolidation (v1.2 opener)** | Part 4 in 3 PRs: (a) runtime_context extensions + `mcss_exec_env_string` + Exec-line rewiring; (b) migrate runtime modules to the globals (kills D1/D5/D6/D7 + N6/N7 structurally); (c) installer globals block (`MCSS_REPO_RAW_URL`, API bases, D15/D16) | Full stage0–stage5 re-run on Deck after each PR — the M1 pass is the regression baseline |
| **M3 — duplication kill-list** | D2/D3/D4 first (each is a live-bug factory), then mediums opportunistically | Same: staged suite + the specific owner check per item |
| **M4 — style-guide retrofit** | One PR per module group: headers (§6.1/6.2), block comments, issue refs; mechanical, no behavior change; shellcheck gate added to CI | `stage1` module smoke on Deck per PR; diff review confirms comments-only |

**New issues to file** (all non-security): "#43-part-2: mode/screen/paths/constants centralization (spec = Part 4)" · one issue per D1–D5 · "D6–D17 medium-duplication batch" · "Style guide adoption + retrofit" · "MCSS_ namespace hygiene (rename window_manager MCSS_* locals)" · "deploy.sh + deploy-freshness check" · "SPLITSCREEN_TEST_OBSERVE_DELAY_S :-12 drift at minecraftSplitscreen.sh:918".

Two things land **immediately** regardless of milestone gates: file the issues above (paper is free), and commit this plan + the style guide into `docs/` so every future session works from the same script.
