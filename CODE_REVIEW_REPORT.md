# Minecraft Splitscreen Code Review Report

## Overview

This review covers the launcher, runtime modules, and installer flow within the `MinecraftSplitscreenSteamdeck` repository. The code is generally well modularized, with strong documentation and defensive shell practices. The main risks are concentrated in broad `set +e` regions, legacy environment override complexity, custom parsing of low-level device files, and a few fragile system-integration branches.

---

## Strengths

- Clear separation between runtime modules and installer modules.
- Centralized runtime context resolution in `modules/runtime_context.sh`.
- Good use of comments documenting bug-fix rationale and module contracts.
- Atomic state writes and lock handling in `modules/instance_lifecycle.sh`.
- Explicit public API comments for many modules.
- Defensive handling of runtime environment assumptions and fallbacks.
- Unified manifest list in `modules/runtime_modules.list`.

---

## Key Issues

### 1. Broad `set +e` sections

- `modules/instance_creation.sh` uses `set +e` across the whole instance creation loop and mod installation flow.
  - Lines: `modules/instance_creation.sh:199-284`, `modules/instance_creation.sh:312`, `modules/instance_creation.sh:753`
- `modules/steam_integration.sh` toggles `set +e` / `set -e` repeatedly around Steam shutdown, backup creation, and downloaded script execution.
  - Lines: `modules/steam_integration.sh:110-131`, `modules/steam_integration.sh:144-203`, `modules/steam_integration.sh:224-263`

Risk: early returns or future edits inside these sections can leave strict mode disabled unintentionally and mask failures.

### 2. Legacy override complexity and implicit structural assumptions

- `modules/runtime_context.sh` still consumes legacy overrides and clamps values in multiple places.
  - Lines: `modules/runtime_context.sh:173-176`, `modules/runtime_context.sh:196`, `modules/runtime_context.sh:205-209`, `modules/runtime_context.sh:505-509`
- `MCSS_MAX_PLAYERS` is structurally limited to 1..4, and the code assumes this in many runtime modules.
- `MCSS_RAW_BINDING` / `CONTROLLER_MONITOR_RAW_BINDING` still create a complex runtime contract between controller enumeration and sandbox masking.

Risk: future change to slot count, binding mode, or environment injection can cause silent misbehavior or divergent paths.

### 3. Custom parsing of `/proc/bus/input/devices`

- `modules/controller_monitor.sh` implements a custom block parser and line splitting using `` separators.
  - Lines: `modules/controller_monitor.sh:148-275`
- Several consumers (`_parse_steam_virtual_devices`, `_parse_all_gamepad_devices`) assume exact field widths and use `IFS=$'\x1f'`.

Risk: changes in `/proc/bus/input/devices` formatting or edge-case device names could break parsing silently.

### 4. Fragile feature branches and unused modules

- `modules/controller_proxy.sh` is documented as a dark module with zero runtime callers in the current tree.
  - Lines: `modules/controller_proxy.sh:101-545`
- This increases maintenance surface without contributing runtime behavior today.

### 5. Hard-coded configuration and magic values

- Runtime constants are often numeric literals rather than centralized tunables.
  - Examples: `ORCHESTRATOR_FIFO_READ_TIMEOUT_S=5`, `ORCHESTRATOR_EMPTY_EXIT_TICKS=2`, `INSTANCE_LIFECYCLE_POLL_INTERVAL_S=0.5`, `CONTROLLER_PROXY_START_TIMEOUT_S=2`, `STEAM_INTEGRATION_GRACEFUL_SHUTDOWN_WAIT_S=3`.
- `modules/instance_creation.sh` includes an embedded default `options.txt` block and hardcoded audio volume values.
  - Lines: `modules/instance_creation.sh:569-577`, `modules/instance_creation.sh:790-832`

Risk: these values are hard to audit, and their intent is less visible than named constants.

### 6. System integration fragility

- `modules/steam_integration.sh` assumes Steam shutdown and `shortcuts.vdf` editing will behave cleanly, but it must also handle external environment and cleanup.
- `modules/preflight.sh` warns about missing `inotifywait` but allows install/launch to continue.
  - Lines: `modules/preflight.sh:64-92`

Risk: runtime behavior may degrade unpredictably on systems with partial dependencies or unusual Steam state.

---

## Refactor Suggestions

### A. Narrow and harden error-handling scopes

- In `modules/instance_creation.sh`:
  - Replace the broad `set +e` span with targeted `|| true` or explicit `if` checks around expected failures.
  - Restore `set -e` by preserving the original shell flags (e.g. using `set +o errexit`/`set -o errexit` or saving `set +e` state more precisely).
- In `modules/steam_integration.sh`:
  - Extract shutdown and backup logic into helper functions that manage error mode locally.
  - Avoid repeated global `set +e` / `set -e` in the main block.

### B. Centralize magic numbers and runtime tunables

- Move numeric runtime defaults into named constants in `modules/runtime_context.sh` or a dedicated config module.
- Expose common values as documented env overrides when appropriate.
- Example values to centralize:
  - `MCSS_STATE_LOCK_TIMEOUT_S`, `MCSS_DISPLAY_PROBE_TIMEOUT_S`
  - `ORCHESTRATOR_FIFO_READ_TIMEOUT_S`, `ORCHESTRATOR_EMPTY_EXIT_TICKS`
  - `INSTANCE_LIFECYCLE_POLL_INTERVAL_S`, `INSTANCE_LIFECYCLE_WINDOW_POLL_TIMEOUT_S`
  - `CONTROLLER_PROXY_START_TIMEOUT_S`, `STEAM_INTEGRATION_GRACEFUL_SHUTDOWN_WAIT_S`

### C. Simplify or harden input-device parsing

- Consider extracting `/proc/bus/input/devices` parsing into a more explicit helper or a Python utility where the input format is easier to express.
- Add unit tests for edge-case blocks containing unusual names, multiple `B:` lines, and missing blank-line trailing termination.
- Clearly document that field 8 is optional and that callers must handle empty `uniq`.

### D. Reduce or clearly mark unused runtime modules

- Either wire `modules/controller_proxy.sh` into runtime flow now, or explicitly mark it as experimental/archived until PR4 path is enabled.
- This will avoid confusion for future maintainers.

### E. Refactor legacy environment override handling

- Consolidate legacy override documentation and behavior in `modules/runtime_context.sh` only.
- Consider mapping `N_SLOTS` / `INSTANCES_DIR` / `LAUNCHER_EXEC` / `SPLITSCREEN_SCREEN_W/H` to the new variables once at process startup, then no longer reading the legacy names elsewhere.

### F. External system interaction cleanup

- In `modules/steam_integration.sh`, use small helper functions for:
  - `ensure_steam_stopped()`
  - `create_shortcuts_backup()`
  - `download_run_add_to_steam()`
- Ensure backup file location and `mktemp` handling do not depend on current working directory unexpectedly.

### G. Make `options.txt` defaults reusable

- Extract the default `options.txt` block in `modules/instance_creation.sh` to a constant or template file.
- Document which values are intentionally tuned for splitscreen and which are simply safe defaults.

---

## Specific Files and Suggested Change Locations

- `modules/runtime_context.sh`
  - Lines `173-176`: `MCSS_MAX_PLAYERS` clamp and structural slot limit.
  - Line `196`: `MCSS_RAW_BINDING` legacy override handling.
  - Lines `205-209`: readonly constant block and variable exposure.
  - Lines `505-509`: `SPLITSCREEN_SCREEN_W/H` override validation.

- `modules/instance_creation.sh`
  - Lines `199-284`: broad `set +e` block during instance creation.
  - Line `312`: `set +e` in `install_fabric_and_mods()`.
  - Lines `569-577`: hard-coded `options.txt` default logic.
  - Lines `753-759`: `set -e` restore and options preservation logic.
  - Lines `790-832`: `options.txt` preserve/restore flow.

- `modules/steam_integration.sh`
  - Lines `110-131`: Steam shutdown and `set +e` block.
  - Lines `144-203`: shutdown polling, backup creation, script download.
  - Lines `224-263`: add-to-steam script download and execution block.

- `modules/controller_monitor.sh`
  - Lines `148-275`: `parse_input_device_blocks` and the related Steam/raw device parsers.
  - Lines `647-694`: `CONTROLLER_MONITOR_RAW_BINDING` path selection and docked-mode source gating.

- `modules/instance_lifecycle.sh`
  - Lines `164-190`: `_atomic_write` and state file handling.
  - Lines `193-217`: `_vendor_of_js_node` and `/proc` device reliance.
  - Line `311-322`: `_build_bwrap_command` construction.
  - Lines `683-690`: comment and atomic-write state consistency.

- `modules/controller_proxy.sh`
  - Lines `114-125`: proxy timeout constants.
  - Lines `138-155`: `_proxy_evsieve_bin` / path resolution.
  - Lines `317-355`: `proxy_start_slot()` implementation and idempotence assumptions.
  - Lines `527-545`: `proxy_stop_all()` and unused module state.

- `modules/dock_detection.sh`
  - Lines `58-172`: DRM detection and `SPLITSCREEN_MODE` override behavior.

- `modules/preflight.sh`
  - Lines `64-92`: hard-stop dependency checks and non-fatal inotify warning.

---

## Recommended Immediate Refactor Tasks

1. Reduce broad `set +e` spans in `modules/instance_creation.sh` and `modules/steam_integration.sh`.
2. Centralize runtime/default constants and document them in `modules/runtime_context.sh`.
3. Harden `/proc/bus/input/devices` parsing in `modules/controller_monitor.sh` with explicit validation and tests.
4. Clarify or archive `modules/controller_proxy.sh` until it is actually wired into runtime.
5. Extract the `options.txt` default block into a reusable template or shared constant.
6. Document legacy override variables and remove their use from any non-initialization code.

---

## Notes

This report is intended to guide refactoring without changing behavior. The code already contains strong defensive comments, but the maintainability of the shell-based runtime would improve by making error-handling and structural assumptions more explicit and narrower.
