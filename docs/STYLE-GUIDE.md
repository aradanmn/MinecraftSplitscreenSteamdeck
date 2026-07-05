# Code Style Guide

Grounded in the existing "new-generation" house style (`instance_lifecycle.sh`, `dock_detection.sh`, `orchestrator.sh`, `watchdog.sh`). Legacy camelCase in `minecraftSplitscreen.sh` is frozen — bring code up to this standard when touched, don't imitate it.

**Golden rule:** stdout is the data protocol; everything human goes to stderr (modules, `[module_name] ` prefix) or `print_*` helpers (installer). Comments explain *why*; git explains *when*.

## 1. Module header (every `modules/*.sh`)

```bash
#!/bin/bash
set -euo pipefail

# =============================================================================
# <MODULE NAME> MODULE
# =============================================================================
# One-to-three lines: what this module does and why it exists.
#
# Public API:
#   func_name(arg1, arg2)   — stdout: <contract>, exit 0/1 <meaning>
#
# Globals PROVIDED (set here, read elsewhere):
#   MODULENAME_FOO          — readonly constant, <purpose>
#
# Globals CONSUMED (set elsewhere, read here):
#   MCSS_MODE               — from runtime_context.sh / orchestrator
#   LOG                     — from launcher entry script
#
# Inputs:  <files/devices/APIs read — state JSON, sysfs, Modrinth API…>
# Outputs: <files written, processes spawned, stderr log prefix>
#
# Environment overrides (for testing):
#   MODULENAME_SOME_PATH    — override <thing>
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.2 2026-07-04  Fix #40: <one-line summary>
#   v1.1 2026-06-27  H11 poll-iteration derivation; window timeout 120s
#   v1.0 2026-06-23  Initial extraction from monolith
# =============================================================================
```

Omit genuinely empty sections rather than writing "none". Keep internal dividers: `# --- Module-level constants ---`, `# --- Internal functions ---`, `# --- Public API ---`.

## 2. Function header (every function; one-liner form OK for trivial helpers)

```bash
# func_name: One-sentence purpose.
# Optional "why" paragraph.
# Inputs:
#   $1 — slot number (1-4)
#   Globals: MCSS_MODE (read), _WATCHDOG_PIDS (read/write)
# Outputs:
#   stdout — "x y w h" geometry, or empty on failure   (data only!)
#   return — 0 success, 1 failure, 2 = <special meaning — MUST be documented>
#   side effects — writes state JSON, spawns bwrap, logs to stderr
```

Document the stdout contract whenever a caller captures output. Short helpers may compress to one line: `# _get_state_file: Return the state file path.`

## 3. Block comments

One present-tense sentence above each logical block saying what it does; add a second "why" sentence only when the code is surprising. Step numbering (`# 3. Deduplicate by hidraw node`) and `# ── section ──` separators are already in use and fine.

## 4. Issue references

- New fixes: `# Fix #40: <what/why>`. Behavior an issue mandates: `# #37: controller disconnect is NOT a crash — keep the slot alive.`
- **All non-security work lives in GitHub issues. Security issues are handled privately — never referenced by number or description in code; write a neutral rationale comment instead.**
- Legacy audit tags (H11, N5, …) are frozen — don't mint new letter-tags; open an issue and use `#N`. When citing old audits in issue comments, cite doc+ID (two audit docs share H-numbering).
- Status flags keep the existing vocabulary: `UNTESTED 2026-07-04`, `VALIDATED 2026-06-26`, tombstone one-liners for removed approaches (the kwin_positioner convention) — never pasted old code.

## 5. Version history — lean on git

Module header: `vX.Y YYYY-MM-DD  <~60-char summary>`, newest first, **max 6 lines** (adding a 7th deletes the oldest). Bump minor when the Public API or globals contract changes. **Functions get no version-history section** — history-worthy context is a dated one-liner at the change site: `# Fix #40 (2026-07-04): reason.`

## 6. Naming

| Thing | Convention | Example |
|---|---|---|
| Public module function | `lower_snake` | `spawn_instance` |
| Private module function | `_lower_snake` (module-prefixed if collision-prone) | `_ensure_state_file` |
| Module constant | `readonly MODULENAME_UPPER` | `DOCK_DETECTION_POLL_INTERVAL_S` |
| Module-private mutable global | `_MODULENAME_UPPER` | `_WATCHDOG_LAST_SEEN` |
| Cross-module global | `MCSS_UPPER` (runtime_context-owned) or documented legacy | `MCSS_MODE`, `LOG` |
| Local | `local lower_snake` | `local drm_path` |
| Legacy camelCase | frozen; rename only with a dedicated issue | `launchSlot` |

Units in names (`_TIMEOUT_S`, `_INTERVAL_S`); ALL-CAPS mnemonic heredoc delimiters (`KWINJS`, `WEOF`).

## 7. Bash rules

1. `set -euo pipefail` in every module/entry script; explicit `set +e` windows where flow must survive failures. Known gaps to fix on next touch: `kwin_positioner.sh`, `minecraftSplitscreen.sh`.
2. `|| true` and `2>/dev/null` only with intent, made obvious by context or comment.
3. Quote everything; unquoted only for deliberate word-splitting, with a comment.
4. `local` for every function variable; `local -a/-A` for arrays; `local -n` namerefs for out-params.
5. `[[ ]]` and `(( ))`, never `[ ]` or `expr`; `${var:-default}` at point of use — wrap in an accessor when the default is used more than once.
6. Cross-module soft guards: `declare -f fn >/dev/null && fn`.
7. Process substitution over pipes when the loop body sets variables (subshell trap — `controller_monitor.sh` documents why).
8. `shellcheck -x` clean on every touched file; suppressions need `# shellcheck disable=SCxxxx  # reason`.
9. Traps for cleanup in anything spawning processes/temp files; atomic writes via `tmp + mv`.
10. Output discipline recap: modules → stderr with `[module_name] ` prefix; installer UX → `print_*` helpers from `utilities.sh` (emoji live inside the helpers — don't double them); stdout → machine-readable data only.

## 8. Pre-commit checklist (solo + AI workflow)

- New function → §2 header. New file → §1 header.
- API/globals change → update Public API + PROVIDED/CONSUMED lists and add a version-history line (§5).
- Tracked bug fix → `# Fix #N:` at the site (§4); security fixes get a neutral comment.
- `shellcheck -x` on touched files; confirm no bare stdout leaks in functions whose stdout is captured.
