# Architecture — Where Things Live

The placement law for this codebase: which module owns which domain, where a
function or global belongs, and the rules that stop helpers and constants from
sprawling across files again. **STYLE-GUIDE.md says how code looks; this file
says where code goes.** When a change and this document disagree, either the
change moves or this document gets a PR — never a silent exception.

Born from the 2026-07-17 audit (AUDIT-ARCHITECTURE-2026-07-17.md), which found
that most remaining duplication is *sites that bypass an existing canonical
home*, not missing homes. The homes exist; this file makes them findable.

---

## 1. The two products and their boundary

| Product | Entry | Modules | Constants root |
|---|---|---|---|
| Installer (runs once) | `install-minecraft-splitscreen.sh` → `main()` in `main_workflow.sh` | `utilities, preflight*, java_management, launcher_setup, version_management, lwjgl_management, mod_management, instance_creation, steam_integration, desktop_launcher, main_workflow` | installer entry constants block (`install-minecraft-splitscreen.sh` ~:85–:296) |
| Runtime (every launch) | `minecraftSplitscreen.sh` → `main()` in `orchestrator.sh` | exactly what `modules/runtime_modules.list` says | `modules/runtime_context.sh` |

`preflight.sh` is deliberately dual-use (in the runtime manifest AND sourced by
the installer). Nothing else crosses the boundary at source time.

Rules:

- **The manifest is the only definition of the runtime module set.** Adding a
  runtime module = one line in `runtime_modules.list`. Never re-list runtime
  modules anywhere else (the installer's `INSTALLER_MODULE_FILES` lists only
  installer modules).
- **An installer module may never call a runtime function at launch time and
  vice versa.** Cross-boundary references are `type`/`declare -f`-guarded and
  commented (existing examples: `setInstanceCfgValue` in instance_lifecycle,
  `_kill_tree` in orchestrator).
- **Standalone scripts** (`uninstall-minecraft-splitscreen.sh`, `deploy.sh`,
  `add-to-steam.py`) get a *documented duplication budget*: they may carry
  private copies of `print_*`, TARGET_DIR, and the manifest parse ONLY with a
  `# PAIRED WITH <canonical site>` comment at the copy. Undocumented copies are
  bugs.

## 2. Domain ownership (functions)

Before writing a helper, find its domain here; the function goes in that module
or it doesn't get written. If two domains seem to apply, the lower-level one
wins (e.g. "move a window for a slot" = window_manager calling dex, never dex
knowing about slots).

| Domain | Owner | Notes |
|---|---|---|
| Environment/mode/paths/screen resolution, cross-module constants | `runtime_context.sh` | resolvers are idempotent; everyone reads the `MCSS_*` exports |
| Dependency gates | `preflight.sh` | install AND launch; hard-stop lists live here only |
| Session event loop, FIFO protocol, mode transitions | `orchestrator.sh` | the only FIFO *reader*; producers only write |
| Slot/instance lifecycle, bwrap sandbox, state-JSON schema | `instance_lifecycle.sh` | ALL state-file reads go through its accessors (`_get_slot_field` etc.) — no raw jq elsewhere |
| Layout policy (grid math, which slot → which cell) | `window_manager.sh` | |
| KWin scripting transport | `kwin_positioner.sh` | qdbus/KWin-JS mechanics only, no layout policy |
| Raw X11 mechanics | `dex.sh` | knows WIDs and atoms, never slots, state files, or `SplitscreenP*` naming |
| Controller enumeration/identity | `controller_monitor.sh` | `/proc/bus/input` parsing lives here only |
| Display topology change detection | `dock_detection.sh` | DRM sysfs + inotify; probing goes through `mcss_query_displays` |
| Slot death detection | `watchdog.sh` | reads state via accessors; emits `SLOT_DIED`; fixes nothing itself |
| Network transport (installer) | `utilities.sh` `fetch_url`/`fetch_url_status` | raw curl/wget allowed ONLY in the pre-utilities bootstrap (`download_modules`) — nowhere else (#47/#88 debt) |
| Installer UX output | `utilities.sh` `print_*` | modules log to stderr with `[module] ` prefix (STYLE-GUIDE golden rule) |
| Mod platform APIs (Modrinth/CurseForge) | `mod_management.sh` | version-match policy + token handling live here ONCE; version_management calls in, doesn't re-implement (#88) |
| Tool-version resolution (MC→Java/LWJGL/Fabric) | `version_management.sh` | target home after the #91 merge |
| Steam/desktop registration | `steam_integration.sh`/`desktop_launcher.sh` (→ one module per #91) | Python gets values via env (`MCSS_*`), never re-derives paths |

**Name collisions:** `main()` and `cleanup()` exist in both products (scope-safe,
never co-sourced). Grandfathered; do not add new cross-product collisions — every
new public function name must be unique repo-wide.

## 3. Where globals live

Decision ladder — first match wins:

1. **Read by 2+ runtime modules, or by launcher + module** → `MCSS_*` in
   `runtime_context.sh` (guarded constants block or a resolver). Never define an
   `MCSS_*` anywhere else on the runtime side.
2. **Read by 2+ installer modules** → the installer entry's constants block
   (`REPO_BASE_URL`, API bases, `MCSS_MAX_PLAYERS`, …).
3. **Needed by BOTH products** → both roots, each copy carrying the `# PAIRED`
   comment pointing at the other (existing pattern:
   `MCSS_MAX_PLAYERS`/`MCSS_INSTANCE_PREFIX`/`MCSS_ACCOUNT_PREFIX`). Keep this
   set as small as possible — currently the pair block plus (per #87) the JVM
   memory defaults.
4. **One module only** → `readonly MODULENAME_UPPER` at the top of that module
   (STYLE-GUIDE §6), listed under "Globals PROVIDED" in the header.
5. **One function only** → `local`. No exceptions.

Corollaries:

- **A numeric literal in logic is a placement decision you skipped.** Name it at
  the right ladder rung. Sleep/timeout/retry values always get `_S`/`_MS` names
  (the audit's §4b list is the current backlog: #86).
- **A constant's existence obligates its use.** Defining
  `MCSS_STATE_LOCK_TIMEOUT_S` and then writing `flock -w 5` is worse than no
  constant — it documents an intention the code ignores (#85/#86 class). When
  you name a value, grep for the literal and convert every site in the same
  commit.
- **Env-overridable defaults** use `: "${NAME:=default}"` at the canonical home
  only; consumers use bare `$NAME` (a consumer-side `:-fallback` re-embeds the
  literal — the 1280/800 and 3072-MB drift pattern).

## 4. Sourcing rules

- The launcher sources `runtime_context.sh` first, resolves environment + paths,
  then sources the manifest modules in list order. Manifest order IS dependency
  order.
- Runtime modules that need `runtime_context.sh` source it themselves,
  idempotently (`$(dirname "${BASH_SOURCE[0]}")/runtime_context.sh` — the
  existing pattern). `watchdog.sh` and `dex.sh` are grandfathered exceptions
  that rely on ambient sourcing; new modules are not.
- Installer modules never source each other — the entry script owns ordering.
  A module that needs another module's function at a specific time gets it via
  `main_workflow.sh` sequencing, not a source line.

## 5. Pre-commit placement checklist

(add to the STYLE-GUIDE §8 checklist)

- [ ] New function: is its domain's owner (§2) the file I'm writing in?
- [ ] New helper: did I grep for an existing one (`grep -rn "name\|synonym" modules/`)?
      The audit found four version-ladders and seven token fetches because
      nobody did.
- [ ] New literal in logic: named at the correct ladder rung (§3), all sites of
      the same literal converted?
- [ ] New global: `MCSS_*` only in a constants root; `MODULENAME_*` only in its
      module; PAIRED comment if it must exist twice?
- [ ] Touched a standalone script's private copy: is the canonical site's
      PAIRED comment still accurate?
