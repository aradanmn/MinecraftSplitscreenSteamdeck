---
name: Codebase Analysis — Known Bugs and Dead Code
description: Confirmed bugs, dead code, and false positives from 2026-03-15 analysis
type: project
---

## CRITICAL — Generator drift: inhibitScreen/uninhibitScreen ✅ FIXED (2026-03-15)
Back-ported in commit `05879f3`. `INHIBIT_PID`, `inhibitScreen()`, `uninhibitScreen()` added to generator; `uninhibitScreen` call added to `perform_cleanup()`. Old instance.cfg-based `writeInstanceSdlEnv`/`clearInstanceSdlEnv` dead pair also removed from heredoc.

---

## MEDIUM — Old writeInstanceSdlEnv (instance.cfg version) still in generator heredoc ✅ FIXED (2026-03-15)
Generator heredoc outputs both the old instance.cfg-based `writeInstanceSdlEnv`/`clearInstanceSdlEnv` (lines 323–343) AND the new wrapper-based versions (lines 660–677). Bash silently ignores the first (overridden by second), but the generator has dead code in its own heredoc. Remove the first pair.

---

## MEDIUM — CurseForge token URL points to FlyingEwok repo (6 places)
Token fetch hardcoded to `raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/token.enc` in:
- `mod_management.sh:342, 720, 889, 1099, 1201`
- `version_management.sh:221`
Should use `REPO_RAW_URL` or be centralized in one `get_cf_api_key()` helper.

---

## MEDIUM — Additional confirmed dead code (2026-03-15 deep analysis) ✅ FIXED (commit fba5ab3)
- `get_creation_instances_dir()`, `get_active_instances_dir()`, `get_launcher_script_path()`, `get_active_executable()`, `get_active_data_dir()` — `path_configuration.sh:366–411` — never called; callers use variables directly
- `validate_path_configuration()`, `print_path_configuration()` — `path_configuration.sh:459, 494` — never called
- `generate_version_header()`, `print_version_info()`, `verify_repo_source()` — `version_info.sh:110, 142, 161` — never called
- `print_generation_config()` — `launcher_script_generator.sh:2537` — never called (contrary to CLAUDE.md note, it DOES exist, just isn't called)
- `normalize_version()` — `utilities.sh:686` — only called by `compare_versions()` which is itself dead
- `should_prefer_flatpak()` — `utilities.sh:346` — never called; path_configuration.sh uses `is_immutable_os()` directly
- `validate_lwjgl_version()` — `lwjgl_management.sh:142` — never called
- `get_lwjgl_version_by_mapping()` — `lwjgl_management.sh:125` — one-line wrapper with one call site, adds no value
- `detect_java()` — `java_management.sh:507` — alias for `detect_and_install_java`, could be inlined
- `get_prism_executable()` in `utilities.sh:241` — overridden by `launcher_setup.sh:288` version; utilities.sh version references `PRISMLAUNCHER_DIR` which is never assigned

---

## MEDIUM — Duplicate logic worth consolidating
- mmc-pack.json heredoc duplicated 3× in `instance_creation.sh` (~242, ~388, ~909) — extract to `write_mmc_pack_json()`
- CurseForge token fetch logic inline 6× — extract to `get_cf_api_key()` helper
- MC version → Java version mapping: in `utilities.sh:754` AND `java_management.sh:57` AND again in `java_management.sh:399` validation block
- Java version matching case blocks in `find_java_installation()` repeated 3× (local jdk scan, system paths, PATH)
- `mc_major_minor=$(get_version_series "$MC_VERSION")` called 8+ times inline in `mod_management.sh`

---

## LOW — Debug echo statements in production code
`install_fabric_and_mods()` in `instance_creation.sh:475–573` has ~15 raw `echo "DEBUG: ..."` / `echo "FINAL URL..."` statements that bypass the logging system and print directly to terminal. Should be replaced with `log_debug`.

---

## LOW — Stale PollyMC reference
`main_workflow.sh:366`: `grep -q "PollyMC\|PrismLauncher"` — PollyMC removed in 3.0.3, grep should be `PrismLauncher` only.

---

## Confirmed Bug (Critical) — Issue #9
### handle_instance_update double-install + contaminated preserve flag
**File:** `modules/instance_creation.sh:148, 317, 900`

`handle_instance_update()` calls `print_*` functions that echo to stdout. The caller captures all stdout into `preserve_options_txt`. Result: the variable is a multiline blob of emoji log lines, never equals `"true"`, so user's `options.txt` is always overwritten with defaults on reinstall.

Additionally, `handle_instance_update` calls `install_fabric_and_mods` at line 900 internally, AND the main loop calls it again at line 317 — mods downloaded twice on update path.

**Fix:** Use a global variable or write to stderr for the boolean return; remove the internal `install_fabric_and_mods` call from `handle_instance_update`.

**Why:** Not yet fixed — added to CLAUDE.md as Issue #9.
**How to apply:** Before touching instance_creation.sh update logic, fix this first or reinstall testing will overwrite user options.txt.

---

## Dead Code (Issue #10) — safe to remove
- `compare_versions()` — `utilities.sh:725` — defined, documented, never called anywhere
- `needs_instance_migration()`, `get_migration_source_dir()`, `get_migration_dest_dir()` — `path_configuration.sh:421–444` — never called; single-launcher architecture makes them irrelevant
- Commented `# "launcher_detection.sh"` reference — `install-minecraft-splitscreen.sh:188`
- `@exports` in `launcher_script_generator.sh` header lists `verify_generated_script` and `print_generation_config` — neither function exists; update docs

---

## Minor
- `tar` glob in `steam_integration.sh:201` — if no shortcuts.vdf files exist, bash passes literal glob to tar, which fails with misleading "could not create backup" warning (failure IS caught, no crash)

---

## False Positives (dismissed)
- Account merge filter deleting P1-P4 MS accounts — impossible (2-char name below MC 3-char minimum)
- `compare_versions` exit code vs string — never called so no wrong usage
- Steam shutdown race condition — handled gracefully already
- Module version numbers out of sync — not worth fixing, only SCRIPT_VERSION matters
