# Testing Strategy — MinecraftSplitscreenSteamdeck

This document describes the full testing approach for the project: what is covered, what is not, how to run tests locally, and how the CI environment is structured.

---

## Quick start

```bash
# Run everything and see READY / NOT READY:
bash tests/grade.sh

# Verbose output (shows all test details):
bash tests/grade.sh --verbose
```

Exit 0 = all suites pass. Use this before marking any task complete.

---

## Test suites

| Suite | File | Count | What it covers |
|---|---|---|---|
| Fixture integrity | `tests/check-fixture.sh` | 4 | Generated script structure, placeholder substitution |
| Utility functions | `tests/test_utilities.bats` | 30 | Version parsing family in `utilities.sh` |
| Path configuration | `tests/test_path_configuration.bats` | 17 | AppImage/Flatpak detection and path wiring |
| Instance creation | `tests/test_instance_creation.bats` | 14 | Manual instance creation, `handle_instance_update` |
| Mod API compatibility | `tests/test_api_mocking.sh` | 27 | Modrinth + CurseForge, version fallback stages |
| Dynamic mode event loop | `tests/test_dynamic_mode.sh` | 23 | Controller add/remove, state machine, PID tracking |
| Full installation workflow | `tests/test_integration.sh` | 53 | `main()` end-to-end, all 10 phases |

**Total: ~168 assertions across 7 suites.**

Additional suites (not in `grade.sh` — run separately):

| Suite | File | What it covers |
|---|---|---|
| Controller simulation | `tests/test_controller_simulation.sh` | `getControllerCount()`, `startControllerMonitor()`, inotifywait event format |
| Environment detection | `tests/test_environment_detection.sh` | `is_immutable_os()` with distro marker files |

---

## Coverage map

### Well covered — grade catches regressions

- `utilities.sh` — all five version functions
- `path_configuration.sh` — full detection and configuration flow, both AppImage and Flatpak paths
- `mod_management.sh` — Modrinth API success/fail, CurseForge, incompatibility, 404, deps, wildcard versions, patch-guard fallback
- `instance_creation.sh` — manual instance creation path, `handle_instance_update`
- Generated launcher — event loop structure, controller state machine, dynamic mode
- `main_workflow.sh` — end-to-end 10-phase orchestration (via integration test)

### Not covered — grade is blind here

| Module / Area | Why not tested | Risk level |
|---|---|---|
| `launcher_setup.sh` download path | Hits GitHub API, downloads real AppImage | Medium — API/CDN outage would break install |
| `install_fabric_and_mods()` | Hits fabricmc.net, downloads real JARs | Medium — version availability |
| `version_management.sh` prompts | Interactive stdin reads | Low — simple prompt logic |
| `steam_integration.sh` | Calls `steam`, `add-to-steam.py` | Low — well-understood surface |
| Actual Minecraft launch | Requires GPU, controllers, display | N/A — hardware gate |

### Coverage estimate: ~75–80% of meaningful logic

---

## CI environment

### Primary CI — `check-generated-script.yml`

Runs on every push and PR to `main`.  Ubuntu 24.04, all 7 grade suites plus the controller simulation test.

### Multi-environment CI — `multi-env.yml`

Runs four parallel jobs to test across distro and environment differences:

| Job | Environment | Purpose |
|---|---|---|
| `ubuntu` | ubuntu-latest | Baseline — same as primary CI |
| `fedora` | fedora:latest container | Verifies no apt/deb assumptions in test scripts |
| `bazzite-sim` | ubuntu + `/etc/bazzite/image_name` | Verifies `is_immutable_os()` detects Bazzite; Flatpak path exercised |
| `controller` | ubuntu + `inotify-tools` | Runs the full inotifywait code path in `test_controller_simulation.sh` |

### ShellCheck — `shellcheck.yml`

Runs `shellcheck --severity=error` on all `.sh` files.  Excludes SC2034 (unused variables common in sourced modules), SC2155 (combined declaration/assignment), SC2046 (word splitting in controlled contexts).

---

## Controller simulation

### What is testable without hardware

| Technique | What it verifies | File |
|---|---|---|
| `HANDHELD_MODE=1` env var | Fast-path in `getControllerCount()` always returns 1 | `test_controller_simulation.sh` |
| Numeric output check | `getControllerCount()` returns 0–4 on any host | `test_controller_simulation.sh` |
| Named pipe creation | `startControllerMonitor()` IPC setup works | `test_controller_simulation.sh` |
| inotifywait + temp dir | js* file create/delete triggers `CONTROLLER_CHANGE:N` event | `test_controller_simulation.sh` |
| Event format regex | All emitted events match `^CONTROLLER_CHANGE:[0-9]+$` | `test_controller_simulation.sh` |

### What requires hardware / root / uinput

| Scenario | Why not automated |
|---|---|
| Real `/dev/input/jsX` device appearing | Requires `uinput` kernel module and root; not available in CI |
| `/proc/bus/input/devices` uhid filtering | Reads real kernel file; path not parameterizable without root |
| Steam halving logic | Requires Steam process running |
| Steam Deck built-in controller path | Requires Steam Deck hardware (`isSteamDeckHardware()` → `0`) |
| Actual Minecraft launch with splitscreen | Requires GPU, display, controllers, Microsoft account |

### Simulating real controller connect/disconnect locally

If you have `python3-evdev` and root:

```bash
# Create a virtual gamepad that appears as /dev/input/jsX
python3 - << 'EOF'
import evdev, uinput, time
cap = {uinput.ABS_X: (0, 255, 0, 0), uinput.ABS_Y: (0, 255, 0, 0)}
device = uinput.Device(list(cap.keys()))
print("Virtual controller created, press Ctrl+C to remove")
time.sleep(30)
EOF
```

After creation, run `bash tests/test_controller_simulation.sh` — `getControllerCount()` will pick up the device via the `/dev/input/js*` fallback path.

---

## Environment simulation

### What is testable without root

`is_immutable_os()` returns a valid exit code on any host. The BATS path configuration tests mock `is_immutable_os()` directly to test both the AppImage and Flatpak paths without needing real OS markers.

### What requires the marker files (root / containers)

| Marker | Env var to activate | Creates |
|---|---|---|
| Bazzite | `SIMULATE_BAZZITE=1` | `/etc/bazzite/image_name` |
| SteamOS | `SIMULATE_STEAMOS=1` | `/etc/steamos-release` |
| NixOS | `SIMULATE_NIXOS=1` | `/etc/NIXOS` |
| Universal Blue | `SIMULATE_UBLUE=1` | `/etc/ublue-os/image_name` |

Run the environment detection tests with simulation enabled:

```bash
SIMULATE_BAZZITE=1 bash tests/test_environment_detection.sh
```

In the `bazzite-sim` CI job this happens automatically via `sudo`.

### Container-based environment testing

You can run a full bazzite-simulation locally with Docker or Podman:

```bash
# Simulate Bazzite immutable OS
docker run --rm -v "$PWD:/repo" -w /repo ubuntu:24.04 bash -c "
    apt-get install -y bats jq -qq &&
    mkdir -p /etc/bazzite && touch /etc/bazzite/image_name &&
    SIMULATE_BAZZITE=1 bash tests/test_environment_detection.sh &&
    bash tests/grade.sh
"

# Simulate Fedora environment
docker run --rm -v "$PWD:/repo" -w /repo fedora:latest bash -c "
    dnf install -y bats jq bash -q &&
    bash tests/grade.sh
"
```

---

## Fixture staleness

`tests/test_dynamic_mode.sh` and `tests/test_controller_simulation.sh` both test against a committed snapshot of the generated launcher: `tests/fixtures/minecraftSplitscreen.sh`.

After any change to `modules/launcher_script_generator.sh`, refresh the fixture:

```bash
sed \
    -e 's|/home/bazzite/|/home/testuser/|g' \
    -e 's|Generated: .*|Generated: 2026-01-01T00:00:00+00:00|' \
    -e 's|# Version: .*(commit: .*))|# Version: FIXTURE (commit: 0000000)|' \
    ~/.local/share/PrismLauncher/minecraftSplitscreen.sh \
    > tests/fixtures/minecraftSplitscreen.sh
chmod +x tests/fixtures/minecraftSplitscreen.sh
```

Then run `bash tests/grade.sh` to verify the refreshed fixture passes all suites.

---

## Mocking conventions

### curl stub (`tests/bin/curl`)

Routes URL patterns to fixture JSON files in `tests/api-fixtures/`.  Handles both direct `curl` calls and `timeout N curl` invocations via argv parsing.

Key routes:
- `*api.modrinth.com/v2/project/*/version*` → `modrinth_${mod_id}.json`
- `*api.curseforge.com/v1/mods/*/files*` → `curseforge_${project_id}.json`
- `*meta.fabricmc.net/v2/versions/loader*` → `fabric_loader.json`

### Network-heavy functions

Mock at the function level:

```bash
get_prism_executable()    { return 1; }   # force manual instance creation
install_fabric_and_mods() { :; }          # skip network download
```

### HOME redirection

Redirect `HOME` to a temp dir BEFORE sourcing any module so `readonly` path constants resolve into throwaway directories:

```bash
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
source modules/path_configuration.sh
# ... tests ...
rm -rf "$TEST_HOME"
```

### Post-source mocks

Always redefine `print_*` and `LOG_FILE=/dev/null` AFTER sourcing. `utilities.sh` overwrites any pre-source definitions:

```bash
source modules/utilities.sh
LOG_FILE=/dev/null
print_success() { :; }
print_warning() { :; }
print_error()   { :; }
```

---

## Adding new tests

### For a new module

1. Run `bash tests/grade.sh` — confirm baseline is READY
2. Identify which existing test file covers adjacent logic
3. Write failing tests first
4. Implement the feature
5. Run `bash tests/grade.sh` — must be READY before marking done

### For a new API fixture

Add a JSON file to `tests/api-fixtures/` named by the mod ID (`modrinth_XXXX.json` or `curseforge_NNNN.json`).  The `tests/bin/curl` stub will route requests to it automatically.

### For a new environment marker

Add a `SIMULATE_<DISTRO>=1`-gated test block to `tests/test_environment_detection.sh` following the pattern of the existing Bazzite/SteamOS blocks.  Add the corresponding step to the `bazzite-sim` job in `.github/workflows/multi-env.yml`.

---

## Known gaps and future work

| Gap | Effort | Value |
|---|---|---|
| `launcher_setup.sh` download path | High — needs binary download mock | Medium |
| `install_fabric_and_mods()` | Medium — needs multi-file fixture | Medium |
| `version_management.sh` prompts | Low — stdin injection | Low |
| Real controller device creation via uinput | High — needs root + kernel module | High for hardware validation |
| Full dynamic mode session (join/leave cycle) | Very high — needs display + Minecraft | Very high — but not automatable |
| Issue #10 disconnect+reconnect before relaunch | Medium — test polling fallback with sequence | Medium |
