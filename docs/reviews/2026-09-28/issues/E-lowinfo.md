title: [E-lowinfo] Window/KWin/dex/Steam integration: low and info findings E11-E13, E15-E26
severity: low
security: no
type: Task
related: none
---
- [ ] E11 — Installer-side duplicate detection is a second encoding of TARGET_DIR
- [ ] E12 — `_get_wid_from_state`'s dex fallback can return several WIDs (no `head -1`)
- [ ] E13 — dex backend rejects hex window ids although both callers' docs say hex is accepted
- [ ] E15 — Geometry cache defaults to predictable `/tmp/mcss-geom` and decides "skip repositioning"
- [ ] E16 — `compute_slot_geometry` / `_reflow_layout` re-embed the 1280/800 screen fallback
- [ ] E17 — Unnamed `sleep 0.2` settle delays in kwin_positioner
- [ ] E18 — Shortcuts backup lands in `$PWD` and is silently skipped on failure
- [ ] E19 — `.desktop` `Exec=` and Steam `exe` are the unquoted launcher path
- [ ] E20 — `add-to-steam.py` robustness gaps (missing userdata traceback, no `config/`, unbounded `urlopen`, `.jpg` saved as `.png`)
- [ ] E21 — `remove-from-steam.py` parser raises `ValueError`/`struct.error` on truncated input
- [ ] E22 — dex `get_prop` format-32 stride, `XFree` leak on empty result, little-endian assumption
- [ ] E23 — dex `action_is_viewable` "gone" branch is unreachable (default Xlib error handler exits)
- [ ] E24 — Stale window_manager header and misleading `[orchestrator] … [kwin frameGeometry]` log tag
- [ ] E25 — Installer discards `add-to-steam.py`'s stderr; helper fetched unpinned
- [ ] E26 — `add-to-steam.py` appid comment inaccurate; VDF entry writer exists in three copies

## Summary

Low/info findings from review E (`modules/window_manager.sh`, `kwin_positioner.sh`, `dex.sh`, `system_integration.sh`, `add-to-steam.py`, `remove-from-steam.py`). Each subsection carries `path:line`, a short description and a fix. Where a diff is given it was generated against the pristine tree on a scratch copy, passes `bash -n` / `python3 -m py_compile` (backend extracted from the `DEXPYEOF` heredoc for dex items) and `git apply --check` from the repo root; E17's diff is generated on top of [E4] (same hunks) and checked after applying E4. `DISPLAY= bash tests/test_window_manager.sh` on a tree with E12/E16/E24 applied stays at the 7/9 baseline (finding T4). E14 and E27 are folded into other agents' issues (A12/D16 and B9) and are not repeated here.

### E11. Installer-side duplicate detection is a second encoding of TARGET_DIR

`modules/system_integration.sh:114`, `:125`; `add-to-steam.py:83-84`; `remove-from-steam.py:187-199`. The installer greps `local/share/PolyMC/minecraft` in every `userdata/*/config/shortcuts.vdf`; the adder writes `"$MCSS_TARGET_DIR/minecraftSplitscreen.sh"` and picks an *unordered* first `userdata/<id>`; the remover iterates all ids sorted. The fragment only matches because `TARGET_DIR` is `$HOME/.local/share/PolyMC` today (relocate it and every re-install appends a duplicate); with two Steam accounts the grep can say "already present" for user A while the adder would have written for user B. Minimal: the `# PAIRED WITH` comment ARCHITECTURE §1 requires. Fuller: move the duplicate check into `add-to-steam.py` using [E7]'s parser and `is_ours`' rules over every userdata id, delete the bash fragment.

```diff
--- a/modules/system_integration.sh
+++ b/modules/system_integration.sh
@@ -111,6 +111,10 @@
         # =============================================================================
         
         # Use PolyMC path signature for duplicate detection.
+        # PAIRED WITH add-to-steam.py (the `exe` it writes is
+        # "$MCSS_TARGET_DIR/minecraftSplitscreen.sh"): this fragment only
+        # matches because TARGET_DIR is $HOME/.local/share/PolyMC today — a
+        # relocated TARGET_DIR makes it never match (duplicate on re-install).
         local launcher_path="local/share/PolyMC/minecraft"
         print_info "Configuring Steam integration for PolyMC"
         
```

### E12. `_get_wid_from_state`'s dex fallback can return several WIDs

`modules/window_manager.sh:149` vs `modules/instance_lifecycle.sh:698` (`| head -1`). `action_search_name` is a substring match over the whole tree; two windows named `SplitscreenP<n>` (a not-yet-reaped previous instance in the slot, or PolyMC's log window renamed by the title-keeper) give a multi-line `$wid`, which `dex_move_resize_remap` passes as one argument → `int("123\n456")` → `ValueError` → exit 2 → "dex remap FAILED" → `_position_slot` returns 1 ([E2]/[E3]).

```diff
--- a/modules/window_manager.sh
+++ b/modules/window_manager.sh
@@ -146,7 +146,9 @@
     # accessor (dex.sh's fallback-less copy of this lookup is deleted); the
     # dex window-name search stays as this module's fallback.
     wid=$(get_window_id "$slot" 2>/dev/null || true)
-    [[ -z "$wid" ]] && wid=$(dex_search --name "${MCSS_WINDOW_TITLE_PREFIX}${slot}" 2>/dev/null || true)
+    # head -1 (as _poll_for_window does): search_name is a substring match
+    # over the whole tree, and a multi-line WID fails int() in the backend.
+    [[ -z "$wid" ]] && wid=$(dex_search --name "${MCSS_WINDOW_TITLE_PREFIX}${slot}" 2>/dev/null | head -1 || true)
     echo "$wid"
 }
 
```

### E13. dex backend rejects hex window ids although both callers' docs say hex is accepted

`modules/dex.sh:282, 291, 305, 380, 412, 418, 435, 453, 465` (`int(args[0])`); docs `modules/window_manager.sh:57` ("WID (decimal or hex)"), `modules/instance_lifecycle.sh:152` ("hex integer"). `int("0x4a00003")` raises → dispatcher exit 2 → silent no-op for anyone feeding a WID from `xprop`/`xwininfo` (the hardware probes). Fix: `int(args[0], 0)` at the nine WID sites (not `:272`, a pid) — accepts `0x…` and decimal (`int('0x4a00003',0) == int('77594627',0)`); dex prints plain decimals so the `0`-prefix rule of base 0 is never hit. One `sed`: `sed -i 's/wid = int(args\[0\])/wid = int(args[0], 0)/; s/wid, \(.*\) = int(args\[0\])/wid, \1 = int(args[0], 0)/' modules/dex.sh` (81-line diff verified; `py_compile` OK).

### E15. Geometry cache defaults to predictable `/tmp/mcss-geom` and decides "skip repositioning"

`modules/window_manager.sh:352-361`; default `modules/runtime_context.sh:327`; re-embedded literal `modules/instance_lifecycle.sh:173`, `:1198`. A pre-existing `/tmp/mcss-geom/slot1` (any local user, or a stale one from another session — #172 fixed only the same-user case) equal to the signature makes `apply_layout` skip the slot; and a dir that exists but is not ours makes the bare `printf >` errexit ([E2] adds `|| true`). Fix: default under the 0700 helper dir and drop the consumer-side re-embeds (ARCHITECTURE §3):

```diff
--- a/modules/runtime_context.sh
+++ b/modules/runtime_context.sh
@@ -324,7 +324,6 @@
     # rationale as SPLITSCREEN_STATE above); default resolved exactly once.
     # mkfifo stays in orchestrator.sh:main — this only names the path.
     export SPLITSCREEN_FIFO="${SPLITSCREEN_FIFO:-/tmp/minecraft-splitscreen.fifo}"
-    export MCSS_GEOM_DIR="${MCSS_GEOM_DIR:-/tmp/mcss-geom}"
 
     # Launch-time runtime dir snapshot. kwin_positioner legitimately rewrites
     # XDG_RUNTIME_DIR when importing the nested session bus — MCSS_RUNTIME_DIR
@@ -347,6 +346,10 @@
         echo "[runtime_context] WARNING: helper dir '$MCSS_HELPER_DIR' not writable — falling back to /tmp (N6/N7 hardening degraded)" >&2
         export MCSS_HELPER_DIR="/tmp"
     fi
+    # Geometry cache: its contents decide "skip repositioning", so it lives
+    # under the 0700 helper dir, not a predictable world-writable /tmp path
+    # where any local user (or a stale foreign session) can plant a slot file.
+    export MCSS_GEOM_DIR="${MCSS_GEOM_DIR:-$MCSS_HELPER_DIR/geom}"
     export MCSS_KWIN_WRAPPER_PATH="${MCSS_KWIN_WRAPPER_PATH:-$MCSS_HELPER_DIR/kwin_wayland_wrapper}"
     export MCSS_SESSION_ENV_BAK="${MCSS_SESSION_ENV_BAK:-$MCSS_HELPER_DIR/session-env.bak}"
 
--- a/modules/instance_lifecycle.sh
+++ b/modules/instance_lifecycle.sh
@@ -170,7 +170,9 @@
     # ids so the cache's WID key matches a different window instance and
     # apply_layout skips repositioning. Resetting state is exactly the moment
     # any prior session's geometry stops being true.
-    rm -f "${MCSS_GEOM_DIR:-/tmp/mcss-geom}"/slot* 2>/dev/null || true
+    # Bare global (ARCHITECTURE §3: no consumer-side re-embed of the default);
+    # guarded for a standalone caller that never ran mcss_resolve_paths.
+    [[ -n "${MCSS_GEOM_DIR:-}" ]] && rm -f "$MCSS_GEOM_DIR"/slot* 2>/dev/null || true
     echo "[instance_lifecycle] Reset state file: $state_file (geom cache cleared)" >&2
 }
 
@@ -1195,7 +1197,7 @@
     if type proxy_stop_slot >/dev/null 2>&1; then
         proxy_stop_slot "$slot" 2>/dev/null || true
     fi
-    rm -f "${MCSS_GEOM_DIR:-/tmp/mcss-geom}/slot${slot}" 2>/dev/null || true
+    [[ -n "${MCSS_GEOM_DIR:-}" ]] && rm -f "$MCSS_GEOM_DIR/slot${slot}" 2>/dev/null || true
 
     if ! slot_is_active "$slot"; then
         echo "[teardown_instance] Slot $slot is not active, nothing to tear down" >&2
```

### E16. `compute_slot_geometry` / `_reflow_layout` re-embed the 1280/800 screen fallback

`modules/window_manager.sh:251-252`, `modules/orchestrator.sh:321`; canonical `modules/runtime_context.sh:637-638`. ARCHITECTURE §3's named drift pattern. `apply_layout` already resolves the screen; the pure function should require its args (all callers, incl. `tests/hardware/stage1_modules.sh:155`, pass them), and `_reflow_layout` runs right after `mcss_resolve_screen --refresh`, which guarantees the globals.

```diff
--- a/modules/orchestrator.sh
+++ b/modules/orchestrator.sh
@@ -318,7 +318,7 @@
     # last-known-good, then 1280x800) is the same tolerance the old probe
     # here reimplemented ad hoc.
     mcss_resolve_screen --refresh
-    local ruleW="${MCSS_SCREEN_W:-1280}" ruleH="${MCSS_SCREEN_H:-800}"
+    local ruleW="$MCSS_SCREEN_W" ruleH="$MCSS_SCREEN_H"   # set by the resolver above
 
     # Reflow via the window manager.
     # NOTE: stderr is intentionally NOT suppressed (was `2>/dev/null`).  The
--- a/modules/window_manager.sh
+++ b/modules/window_manager.sh
@@ -248,8 +248,10 @@
 compute_slot_geometry() {
     local slot="${1:-1}"
     local grid_mode="${2:-full}"
-    local screen_w="${3:-${MCSS_SCREEN_W:-1280}}"
-    local screen_h="${4:-${MCSS_SCREEN_H:-800}}"
+    # Pure function: the caller (apply_layout) resolves the screen via
+    # mcss_resolve_screen; no 1280/800 re-embed here (ARCHITECTURE §3).
+    local screen_w="${3:?compute_slot_geometry: screen_w required}"
+    local screen_h="${4:?compute_slot_geometry: screen_h required}"
 
     case "$grid_mode" in
         full)
```

### E17. Unnamed `sleep 0.2` settle delays in kwin_positioner

`modules/kwin_positioner.sh:250`, `:308`. A timing constant that decides whether a placement is aborted by `unloadScript`, duplicated in two functions, no `_S` name (ARCHITECTURE §3, #86). Diff generated on top of [E4] (same hunks):

```diff
--- a/modules/kwin_positioner.sh
+++ b/modules/kwin_positioner.sh
@@ -58,6 +58,15 @@
 # like the launcher prologue.
 source "$(dirname "${BASH_SOURCE[0]}")/runtime_context.sh"
 
+# --- Module-level constants ---
+# Guarded (house pattern): modules are re-sourceable within one process.
+if [[ -z "${_KWIN_POSITIONER_CONSTANTS_LOCKED:-}" ]]; then
+    # Settle time between Script.run and unloadScript: unload can abort a
+    # live run, so give KWin's event loop one tick to apply the geometry.
+    readonly KWIN_POSITIONER_RUN_SETTLE_S=0.2
+    _KWIN_POSITIONER_CONSTANTS_LOCKED=1   # process-local — NOT exported
+fi
+
 # kwin_qdbus: qdbus wrapper — prefer the Qt6 build (Plasma 6).
 # Inputs: $@ — forwarded verbatim to qdbus6/qdbus
 # Outputs:
@@ -254,7 +263,7 @@
             || echo "[kwin_positioner] WARNING: Script.run failed for '$name' (id $id) — unloading anyway" >&2
     fi
     # Let run() apply the geometry before we unload (unload can abort a live run).
-    sleep 0.2
+    sleep "$KWIN_POSITIONER_RUN_SETTLE_S"
     # `|| true`: cleanup is best-effort; the rm -f must run either way (E4).
     kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$name" >/dev/null 2>&1 || true
     rm -f "$jsfile"
@@ -315,7 +324,7 @@
     kwin_qdbus org.kde.KWin "/Scripting/Script${id}" org.kde.kwin.Script.run >/dev/null 2>&1 \
         || kwin_qdbus org.kde.KWin "/${id}" org.kde.kwin.Script.run >/dev/null 2>&1 \
         || echo "[kwin_positioner] WARNING: Script.run failed for '$name' (id $id) — unloading anyway" >&2
-    sleep 0.2
+    sleep "$KWIN_POSITIONER_RUN_SETTLE_S"
     kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$name" >/dev/null 2>&1 || true
     rm -f "$jsfile"
     return 0
```

### E18. Shortcuts backup lands in `$PWD` and is silently skipped on failure

`modules/system_integration.sh:213`, `:222-227` (`local backup_path="$PWD/steam-shortcuts-backup-$(date …).tar.xz"`, also SC2155). Under `curl | bash` `$PWD` is wherever the shell was (`/`, a read-only mount, the SD card) and a failed `tar` only prints "proceeding without backup". Fix: once [E8] lands the adder writes `shortcuts.vdf.mcss-backup-<ts>` beside the file (the remover's convention) — delete the tar step; if a tar is kept, write it under `$TARGET_DIR/backups/` and make a failure abort the Steam step rather than proceed.

### E19. `.desktop` `Exec=` and Steam `exe` are the unquoted launcher path

`modules/system_integration.sh:488`, `add-to-steam.py:131`. The Desktop Entry spec requires quoting for paths with spaces/reserved characters, and `TARGET_DIR` inherits `$HOME`; Steam itself stores exes `"quoted"` (the remover's `strip('"')` expects both). The crc input stays the unquoted `EXE` (the appid is stored explicitly, so the pair stays consistent — E26).

```diff
--- a/modules/system_integration.sh
+++ b/modules/system_integration.sh
@@ -485,7 +485,7 @@
 Type=Application
 Name=Minecraft Splitscreen
 Comment=$launcher_comment
-Exec=$launcher_script_path
+Exec="$launcher_script_path"
 Icon=$icon_desktop
 Terminal=false
 Categories=Game;
--- a/add-to-steam.py
+++ b/add-to-steam.py
@@ -128,7 +128,7 @@
     b += x00 + str(index).encode() + x00  # Shortcut index
     b += x02 + b'appid' + x00 + struct.pack('<I', appid)  # AppID
     b += x01 + b'appname' + x00 + appname.encode() + x00  # App name
-    b += x01 + b'exe' + x00 + exe.encode() + x00          # Executable
+    b += x01 + b'exe' + x00 + f'"{exe}"'.encode() + x00   # Executable (Steam stores exes quoted; remove-from-steam.py strips the quotes — PAIRED)
     b += x01 + b'StartDir' + x00 + startdir.encode() + x00  # Working dir
     b += x01 + b'LaunchOptions' + x00 + b'launchFromPlasma' + x00  # Auto-start nested session
     b += x01 + b'icon' + x00 + config_dir.encode() + b'/grid/' + str(appid).encode() + b'_icon.ico' + x00  # Icon path
```

### E20. `add-to-steam.py` robustness gaps

`add-to-steam.py:84` (uncaught `FileNotFoundError` when Steam has never run — hidden by the installer's `2>/dev/null`, E25), `:92-94` (assumes `config/` exists), `:158` (`.jpg` main grid saved as `<appid>.png`), `:164-166` (`urlopen` with no timeout — five sequential downloads can each hang the installer, PRINCIPLES #6). Fix: clear error when `userdata` is missing, `sorted()` for a deterministic user pick, `os.makedirs(config_dir, exist_ok=True)`, extension from the URL (the remover's pattern already accepts `png|jpg|ico` — PAIRED; an existing install keeps its old `<appid>.png` and gains a `.jpg`, both removed by the remover), `urlopen(req, timeout=15)` (matches `fetch_url`). 44-line diff verified (`py_compile` OK, applies after [E7]/[E8]).

### E21. `remove-from-steam.py` parser raises `ValueError`/`struct.error` on truncated input

`remove-from-steam.py:58` (`data.index` → `ValueError`), `:84` (`struct.unpack` → `struct.error`), handler `:313` (`except (VdfError, OSError)`). Fail-safe already (nothing written, non-zero exit) but the user sees a traceback instead of "ERROR on <path>: … refusing to modify". Measured: a file cut mid-string gives `ValueError: subsection not found` on pristine and `ERROR on …: unterminated string at offset 25 — refusing to modify this file` with the patch. Mirror the two guards into [E7]'s parser copy (PAIRED).

```diff
--- a/remove-from-steam.py
+++ b/remove-from-steam.py
@@ -55,7 +55,9 @@
 
 def _read_cstr(data, i):
     """Read a NUL-terminated byte string starting at i -> (bytes, next_index)."""
-    end = data.index(b"\x00", i)
+    end = data.find(b"\x00", i)
+    if end < 0:
+        raise VdfError(f"unterminated string at offset {i}")
     return data[i:end], end + 1
 
 
@@ -81,6 +83,8 @@
         elif t == T_STR:
             val, i = _read_cstr(data, i)
         elif t == T_INT:
+            if i + 4 > len(data):
+                raise VdfError(f"truncated int at offset {i}")
             val = struct.unpack("<I", data[i:i + 4])[0]
             i += 4
         else:
@@ -310,8 +314,12 @@
     for path in files:
         try:
             total += process(path, target_dir, dry_run)
-        except (VdfError, OSError) as e:
-            print(f"ERROR on {path}: {e}", file=sys.stderr)
+        except (VdfError, OSError, ValueError, struct.error) as e:
+            # ValueError/struct.error: any parser gap not yet turned into a
+            # VdfError — still fail-safe (nothing written), but reported the
+            # same way instead of as a traceback.
+            print(f"ERROR on {path}: {e} — refusing to modify this file. "
+                  "Remove the shortcut manually from Steam.", file=sys.stderr)
             return 1
     print(f"done — {total} shortcut(s) "
           f"{'would be ' if dry_run else ''}removed")
```

### E22. dex `get_prop` format-32 stride, `XFree` leak on empty result, little-endian assumption

`modules/dex.sh:194-201`, `:244-248`. Xlib returns format-32 data as an array of C `long` (8 bytes on x86_64 — the module's own N9 comment says so for the *write* side); `n * fmt // 8` is only right for `n == 1`, which is the sole format-32 read today (`_NET_WM_PID`), so it works by coincidence; a multi-element read (`_NET_WM_STATE`) would return interleaved garbage. `XFree` is skipped on the early return (Xlib allocates even for an empty result). `'<I'` should be native. Fix (43-line diff, `py_compile` OK): read with the real stride and re-pack each element as native `uint32`, move `XFree` into a `finally`, `'=I'` in `get_pid`:

```python
    if status != 0 or not prop:
        return None
    try:
        if not nitems.value:
            return None
        fmt, n = actual_format.value, nitems.value
        if fmt == 32:
            longs = ctypes.cast(prop, ctypes.POINTER(ctypes.c_ulong))
            return b''.join(struct.pack('=I', longs[k] & 0xFFFFFFFF) for k in range(n))
        data_ptr = ctypes.cast(prop, ctypes.POINTER(ctypes.c_ubyte))
        return bytes(data_ptr[:n * fmt // 8])
    finally:
        _lib.XFree(prop)
```

### E23. dex `action_is_viewable` "gone" branch is unreachable

`modules/dex.sh:454-457`; consumer `modules/instance_lifecycle.sh:1152`. A destroyed window makes `XGetWindowAttributes` raise a BadWindow protocol error; with no `XSetErrorHandler` installed the default handler prints "X Error of failed request" and `exit(1)`s the interpreter, so the `== 0` → `print("gone")` branch (and `action_getgeometry`'s) never runs. Works today only because every caller does `… 2>/dev/null || echo gone`/`|| echo ""`. Fix: either install a no-op `XSetErrorHandler` via `ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)` at backend start so the documented return paths are real, or delete the dead branch and document the exit-code contract in the `dex_is_viewable` header ("non-zero exit = gone; the shell wrapper's `|| echo gone` is the contract").

### E24. Stale window_manager header and misleading log tag

`modules/window_manager.sh:7-8` ("applies layout via xdotool. Maintains black placeholder windows" — both removed 2026-06-23 per `:98-102`, `:389`), `:11-13` (Public API omits `sync_apply_layout` and the return contracts — fixed by [E3]), `:362` (`echo "[orchestrator] WINDOW … [kwin frameGeometry]"` emitted from window_manager even when the dex override-redirect path — PRIMARY since 2026-06-27 — was taken). Header diff below; for `:362` change the prefix to `[window_manager]` and drop the `[kwin frameGeometry]` suffix (the `PATH-CAPTURE` line already names the path taken) — that line sits inside [E2]'s hunk, so fold it into E2's PR.

```diff
--- a/modules/window_manager.sh
+++ b/modules/window_manager.sh
@@ -5,7 +5,9 @@
 # WINDOW MANAGER MODULE
 # =============================================================================
 # Computes window geometry for splitscreen Minecraft instances and applies
-# layout via xdotool. Maintains black placeholder windows for vacant slots.
+# the layout via dex (override_redirect unmap/remap cycle — PRIMARY since
+# 2026-06-27) with KWin-scripting frameGeometry as the no-WID fallback.
+# (xdotool and the black placeholder windows were removed 2026-06-23.)
 #
 # Public API:
 #   compute_grid_mode(active_slots)          — stdout: "full", "half", or "quad"
```

### E25. Installer discards `add-to-steam.py`'s stderr; helper fetched unpinned

`modules/system_integration.sh:264-268`, `:291`. `python3 "$steam_script_temp" 2>/dev/null` hides every traceback (E20's failures show only as "encountered errors … common causes: PolyMC not found"). The `fetch_url "${MCSS_REPO_RAW_URL}/add-to-steam.py"` fallback executes whatever `main` serves, unpinned — the same trust decision as the `curl | bash` bootstrap and `uninstall-minecraft-splitscreen.sh:421`, so not a new exposure, but now made in three places; consider pinning `MCSS_REPO_RAW_URL` to a tag. Stderr capture (the installer has no `$LOG` variable to append to, so a temp file + `tail -5` on failure):

```diff
--- a/modules/system_integration.sh
+++ b/modules/system_integration.sh
@@ -286,14 +286,19 @@
                 # all. This was silently failing behind the `2>/dev/null`
                 # below — add-to-steam.py's own hardcoded fallback URL matches
                 # this one today, which is the only reason nothing broke.
+                # E25: keep the script's stderr — a traceback was the ONLY
+                # evidence of why the step failed, and it was thrown away.
+                local _ats_err
+                _ats_err=$(mktemp)
                 if env MCSS_TARGET_DIR="$TARGET_DIR" \
                     MCSS_STEAMGRIDDB_ICON_URL="$MCSS_STEAMGRIDDB_ICON_URL" \
-                    python3 "$steam_script_temp" 2>/dev/null; then
+                    python3 "$steam_script_temp" 2>"$_ats_err"; then
                     print_success "✅ Minecraft Splitscreen successfully added to Steam library"
                     print_info "   → Custom artwork downloaded and applied"
                     print_info "   → Shortcut configured with proper launch parameters"
                 else
                     print_warning "⚠️  Steam integration script encountered errors"
+                    [[ -s "$_ats_err" ]] && tail -n 5 "$_ats_err" | sed 's/^/   │ /' >&2
                     print_info "   → You may need to add the shortcut manually"
                     print_info "   → Common causes: PolyMC not found, Steam not installed, or permissions issues"
                 fi
@@ -303,8 +308,8 @@
                 print_info "   → Check your internet connection and try again later"
             fi
             
-            # Clean up temporary file
-            rm -f "$steam_script_temp" 2>/dev/null || true
+            # Clean up temporary files
+            rm -f "$steam_script_temp" "${_ats_err:-}" 2>/dev/null || true
             
             # Re-enable strict error handling
             set -e
```

### E26. `add-to-steam.py` appid comment inaccurate; VDF entry writer exists in three copies

`add-to-steam.py:138-139` (`crc32(APPNAME + EXE)` — Steam's documented input is `exe + appname`; the comment says "matches Steam's logic" and invites someone to "fix" one side), `:114-136` (`make_entry`), `tests/test_uninstall_purge.sh:84-94` (private copy, no `# PAIRED` comment), `remove-from-steam.py:91-104` (`serialize_map`, the canonical inverse). The pair stays consistent because the appid is stored in the entry and read back, so the comment is the bug; the three-copy layout is PRINCIPLES #9. Comment fix below; have the fixture build entries with the remover's `serialize_map` (import via `importlib`, as `_shortcut_names` already does) instead of hand-packing bytes.

```diff
--- a/add-to-steam.py
+++ b/add-to-steam.py
@@ -135,7 +135,10 @@
     b += x08  # End of entry
     return b
 
-# --- Generate a unique appid for the shortcut (matches Steam's logic) ---
+# --- Generate a stable appid for the shortcut. NOTE: crc32(APPNAME + EXE) is
+# NOT Steam's own derivation (Steam hashes exe + appname); harmless because the
+# appid is stored explicitly in the entry and remove-from-steam.py reads it back
+# (PAIRED) — do not "fix" the order on one side only. ---
 appid = 0x80000000 | zlib.crc32((APPNAME + EXE).encode("utf-8")) & 0xFFFFFFFF
 entry = make_entry(index, appid, APPNAME, EXE, STARTDIR)
 
```

## Hardware verification

Runtime items (E12, E13, E15, E16, E17, E22, E23, E24) are covered by one docked 4-up session (stage3_hotplug) plus one handheld launch (stage2_handheld) after the batch lands: tiles land in the right cells, `grep -c "dex remap FAILED" ~/.local/share/PolyMC/splitscreen-debug-latest.log` is 0, `ls "$XDG_RUNTIME_DIR/mcss/geom/"` holds `slot<n>` files during play (E15) and `/tmp/mcss-geom` is no longer created, and the log's positioning lines carry the `[window_manager]` prefix (E24). E13 additionally: from Desktop Mode over SSH, `DEX_DISPLAY=:0 python3 "$XDG_RUNTIME_DIR/dex_backend_$UID.py" getgeometry 0x<hex from xwininfo>` prints a geometry. Installer/uninstaller items (E11, E18, E19, E20, E21, E25, E26) are CI + unit test only, with one stage0b_install pass to confirm the `.desktop` launcher still opens from the KDE menu with the quoted `Exec=` (E19) and that a deliberately broken `add-to-steam.py` run (e.g. `HOME=/nonexistent`) now prints the Python error lines under the "encountered errors" warning (E25/E20).

## References

Review E11–E13, E15–E26 (docs/reviews/2026-09-28/E-window-system.md; consolidated docs/CODE-REVIEW-2026-09-28.md §6 table). ARCHITECTURE §1 (`# PAIRED WITH`), §3 (consumer-side `:-` re-embeds, `_S` timing names); PRINCIPLES #6, #9; STYLE-GUIDE §7. Related individual issues: [E2]/[E3] (E12, E15, E24 touch the same function), [E4] (E17 stacks on it), [E7]/[E8] (E11, E19, E20, E21, E26 touch the same scripts). #172 (stale geom cache, same-user case), #86 (named timing constants), #45/D16 (relocatable TARGET_DIR).
