# Review E — window / KWin / dex / Steam & desktop integration

Files: `modules/window_manager.sh`, `modules/kwin_positioner.sh`, `modules/dex.sh`,
`modules/system_integration.sh`, `add-to-steam.py`, `remove-from-steam.py`.
Cross-module callees opened: `modules/instance_lifecycle.sh` (spawn_instance
steps 7–9, `_poll_for_window`, `get_window_id`), `modules/orchestrator.sh`
(`_reflow_layout`, the backgrounded spawn group), `modules/runtime_context.sh`
(`mcss_resolve_paths`/`mcss_resolve_screen`), `modules/utilities.sh`
(`mcss_prompt`, `fetch_url`), `uninstall-minecraft-splitscreen.sh`
(`remove_steam_shortcut`), `tests/test_uninstall_purge.sh` (fixture).

Known-issue docs grepped (BUG-AUDIT-2026-06-24-followup, AUDIT-2026-07-21,
CODE-REVIEW-2026-07-21-CLOSED, IMPROVEMENTS-ANALYSIS-2026-08-15, TODO): none of
the findings below appear there except where tagged.

---

## High

### E1. dex `XWindowAttributes` ctypes struct is mis-declared — `map_state` reads the colormap XID, so `dex_is_viewable` can never report "viewable"
- **Severity:** High
- **Category:** bug
- **File:** `modules/dex.sh:102-117` (struct), `modules/dex.sh:448-458` (`action_is_viewable`), consumer `modules/instance_lifecycle.sh:1148-1160` (map-keeper #57)
- **Status:** CONFIRMED
- **What:** The Python struct puts `map_installed`/`map_state` directly after
  `save_under`:
  ```python
  ('save_under', Bool), ('map_installed', Bool),
  ('map_state', ctypes.c_int),
  ...
  ('override_redirect', Bool), ('screen', ctypes.c_void_p),
  ('colormap', ctypes.c_ulong),
  ```
  In `Xlib.h` (checked on this host, `/usr/include/X11/Xlib.h:325-328`) the
  real order is `save_under, Colormap colormap, map_installed, map_state, …,
  override_redirect, screen`. Computed offsets: dex's `map_state` is at byte
  80; the real `map_state` is at byte 92 and byte 80 is the low 32 bits of
  `colormap`. Total size happens to match (136), so there is no overflow — the
  values are just silently wrong. `action_is_viewable` then does
  `print("viewable" if a.map_state == 2 else "unmapped")`, i.e. it prints
  "viewable" only when the window's colormap XID is 2. (`override_redirect`
  is also misread — offset 112 vs 120 — but nothing reads it back.)
- **Failure scenario:** Every spawn: the #57 map-keeper polls
  `dex_is_viewable` every `INSTANCE_LIFECYCLE_MAP_KEEP_INTERVAL_S=2` s for
  45 iterations; it always gets "unmapped", so it calls `dex_map_raise`
  (XMapWindow + XRaiseWindow) 45 times per slot and logs
  "map-keeper: re-mapped unmapped window" 45 times, regardless of the
  window's true state. The "only re-show when the game actually unmapped it"
  design is not what runs; with 4 slots there are 4 keepers raising their
  windows against each other for 90 s. Any future consumer of
  `dex_is_viewable` (e.g. a watchdog "is the tile visible" probe) would be
  misled the same way.
- **Fix:** Reorder the struct to match Xlib.h exactly:
  `('save_under', Bool), ('colormap', ctypes.c_ulong), ('map_installed', Bool),
  ('map_state', ctypes.c_int), ('all_event_masks', ctypes.c_long),
  ('your_event_mask', ctypes.c_long), ('do_not_propagate_mask', ctypes.c_long),
  ('override_redirect', Bool), ('screen', ctypes.c_void_p)`. Add a unit test
  that asserts `XWindowAttributes.map_state.offset == 92` and
  `sizeof == 136` on x86_64 (mutation-test by swapping two fields, #4).

### E2. `apply_layout` is not errexit-safe: a positioning failure kills the backgrounded `spawn_instance` group silently (no map-keeper, no post-spawn reflow, no slot release, spawn log destroyed unread)
- **Severity:** High
- **Category:** bug
- **File:** `modules/window_manager.sh:360`, `:383`, `:317-319`, `:198`, `:361`; callers `modules/instance_lifecycle.sh:1138`, `modules/orchestrator.sh:448-470`
- **Status:** CONFIRMED (empirically, see below)
- **What:** `apply_layout` calls `_position_slot "$slot" "$x" "$y" "$w" "$h"`
  (L360, again at L383 in the re-assert loop) as a bare statement; the
  function legitimately returns 1 ("no wid or pid available to position", or
  the dex remap readback was empty, or `kwin_place_windows` failed). L317
  `dex_list_windows 2>/dev/null | while read …` is a bare pipeline under
  `pipefail` (the backend exits 1 when it cannot open the display). L198
  `kwin_place_windows …` is bare. L361 `printf '%s' "$_sig" > "$_gf"` is
  bare (redirection failure). All modules run `set -euo pipefail`.
  `spawn_instance` calls `sync_apply_layout "$updated_active" "" ""` bare
  (instance_lifecycle L1138), and the orchestrator runs `spawn_instance …
  >"$_si_log" 2>&1` bare inside `{ … } &` (orchestrator L456). None of these
  are in an exit-status-tested context, so errexit propagates: the first
  failing `_position_slot` terminates the whole backgrounded brace group.
  Verified with a minimal bash reproduction: the `rc=$?` line after the
  failing call never runs and the log only contains lines written before the
  failure.
- **Failure scenario:** `_poll_for_window` times out (LWJGL3 title never
  restored and `_NET_WM_PID` not yet set) → `window_id` empty → in
  `_position_slot` `wid` is empty → falls to the KWin path → inside gamescope
  `kwin_positioner_available` fails (or `kwin_place_windows` returns 1) →
  `return 1` → errexit. Result: spawn_instance never reaches step 9
  (map-keeper), the orchestrator's `_si_rc=$?` / "slot released" /
  `_reflow_layout` code after L456 is skipped, and the EXIT trap `rm -f
  "$_si_log"` deletes the spawn log before `sed < "$_si_log" >&2` ever runs —
  the diagnostics for exactly the failing launch are gone. The slot stays
  `active:true` with a running but unpositioned (854x480) game and nothing
  retries.
- **Fix:** In `apply_layout` make every fallible call status-tested:
  `_position_slot … || _failed+=("$slot")` (both sites),
  `if type dex_list_windows …; then dex_list_windows 2>/dev/null | while … ; done || true; fi`,
  `kwin_place_windows "$pid $x $y $w $h" || return 1` in `_position_slot`,
  and `{ mkdir -p "$_gd" && printf '%s' "$_sig" > "$_gf"; } 2>/dev/null || true`.
  Then return a real status (see E3). Separately (orchestrator, not this
  review's file): `spawn_instance … >"$_si_log" 2>&1 || _si_rc=$?` so the
  cleanup branch is reachable at all under `set -e`.

### E3. `apply_layout`/`sync_apply_layout` never return non-zero on positioning failure, so the orchestrator's H10 reflow-retry (`_REFLOW_NEEDED=1`) is dead code
- **Severity:** High
- **Category:** logic / contract mismatch
- **File:** `modules/window_manager.sh:285-397` (no return contract; last statement is the `if … REASSERT` block), consumer `modules/orchestrator.sh:334-341`
- **Status:** CONFIRMED (empirically: `if ! apply; then … else echo "returned 0 despite pos failing"; fi` prints the latter)
- **What:** `_reflow_layout` relies on `if ! sync_apply_layout "$active" "$ruleW" "$ruleH"; then … _REFLOW_NEEDED=1; return 1; fi` and its comment says H10 "surface a reflow failure (return non-zero) … lets the event loop actually RETRY". But `apply_layout` has no explicit return; its exit status is that of the trailing `if [[ "${WINDOW_MANAGER_REASSERT…}" == "1" && … ]]` block (0 whether the condition is false or the body's `echo` ran). Because the call is inside `if !`, errexit is suppressed for the entire call chain, so `_position_slot`'s `return 1` is simply discarded. The "return — 1 on failure" documented in `_position_slot` never reaches anyone.
- **Failure scenario:** Dock/undock → `DISPLAY_MODE_CHANGE` → `_reflow_layout` → every `_position_slot` fails (KWin unreachable during the mode switch) → `apply_layout` returns 0 → `_REFLOW_NEEDED=0` → no retry; windows stay tiled for the old output. The retry that H10 "implemented" cannot fire.
- **Fix:** Track failures in `apply_layout` (`local -a _failed=()`; append on each failed `_position_slot`), log them, and end with `(( ${#_failed[@]} == 0 ))`. Document the return contract in the function header (STYLE-GUIDE §2). Add a mutation-tested unit test that stubs `_position_slot` to `return 1` and asserts `apply_layout` returns 1.

## Medium

### E4. `kwin_place_windows`/`kwin_set_noborder`: qdbus failures under `set -e` abort mid-function, leaking the generated `.js` and leaving the script loaded in KWin; the H8 "no valid id" branch is unreachable for a non-zero `loadScript`
- **Severity:** Medium
- **Category:** robustness / resource leak
- **File:** `modules/kwin_positioner.sh:237`, `:246-251`, `:298`, `:306-309`
- **Status:** CONFIRMED (by construction; the module has `set -euo pipefail` at L2)
- **What:** `id=$(kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$jsfile" "$name" 2>/dev/null)` — a failing command substitution in an assignment triggers errexit before the `if ! [[ "$id" =~ ^[0-9]+$ ]]` guard, so the `rm -f "$jsfile"` at L241/L302 is skipped. L247 (`kwin_qdbus … "/${id}" org.kde.kwin.Script.run` in the `if` *body*) and L251/L309 (`unloadScript`) are bare: a failed run → function aborts before `unloadScript` and before `rm -f`. Loaded-but-not-unloaded one-shot scripts accumulate in KWin — the header explicitly says "loadScript won't reload a name that's already loaded; unique avoids that and accumulation", but only when unload actually happens.
- **Failure scenario:** KWin bus goes away between `_kwin_import_session_env` and `loadScript` (nested Plasma teardown, or `qdbus6` timing out): errexit ends `kwin_place_windows`; in the spawn path this is the E2 chain; in all paths `$MCSS_HELPER_DIR/mcss_place_XXXXXX.js` is left behind and, if `loadScript` succeeded but `run` failed, the script stays registered in KWin for the session.
- **Fix:** `id=$(kwin_qdbus … 2>/dev/null) || id=""`; wrap run/unload with `|| true` (intent-commented), and use a local `trap 'rm -f "$jsfile"' RETURN`, or restructure as `_kwin_run_oneshot <jsfile>` with a single cleanup path shared by both functions (the two bodies are currently a near-verbatim copy — #9).

### E5. `kwin_set_noborder` interpolates `${pid}` into KWin JavaScript without the H7 integer check — and has zero callers (dead public API with a stale "called in spawn_instance" comment)
- **Severity:** Medium
- **Category:** security (JS injection hardening) / dead-code
- **File:** `modules/kwin_positioner.sh:270-271`, `:287`, `:291`; stale references `minecraftSplitscreen.sh:719`, `docs/TODO.md:321`
- **Status:** CONFIRMED
- **What:** `local pid="$1"; [[ -z "$pid" ]] && return 1` is the only validation, then `if (!w || w.pid !== ${pid}) continue;` and `print("[kwin_noborder] pid=${pid} …")` are written into a script KWin executes. `kwin_place_windows` got the H7 fix (L136-143: every field must match `^[0-9]+$` "before interpolating into the JS literal"); this sibling did not. `grep -rn kwin_set_noborder` finds only the definition — no runtime or test caller — while `minecraftSplitscreen.sh:719` still says "Decoration is handled by kwin_set_noborder <pid> in spawn_instance" (spawn_instance actually uses `dex_set_decorations`, instance_lifecycle L1129-1131).
- **Failure scenario:** Today `pid` would come from `get_java_pid` (state JSON), so exploitation needs a poisoned state file; but a caller passing an empty-after-trim or garbage value (`"123 456"`, `"abc"`) produces a JS syntax error or a bare identifier that KWin silently evaluates — the very failure H7 describes. As dead code it is also the kind of function that gets re-wired later without anyone re-reading it.
- **Fix:** Either delete it (Fix #90 style: zero references) together with the stale comment at `minecraftSplitscreen.sh:719`, or add `[[ "$pid" =~ ^[0-9]+$ ]] || { echo "[kwin_positioner] WARNING: bad pid '$pid'" >&2; return 1; }` and route both generators through one `_kwin_run_oneshot` (E4).

### E6. `_dex_run` has no timeout — every dex call is an unbounded synchronous X round-trip in the orchestrator's hot path (`signal` is imported for this and never used)
- **Severity:** Medium
- **Category:** principle-violation (#6 bounded waits) / robustness
- **File:** `modules/dex.sh:531-535` (`_dex_run`), `:91` (`import … signal`), every `XSync`/`XGetWindowAttributes` in the backend (e.g. `:383-408`)
- **Status:** CONFIRMED
- **What:** `DEX_DISPLAY=… python3 "$DEX_PY_SCRIPT" "$@"` with no `timeout`, no `signal.alarm`, no `XSetIOErrorHandler`. `window_manager.sh:312-314` justifies never using xdotool here because it "can block indefinitely inside gamescope's XWayland, freezing the synchronous caller" — dex makes the same blocking Xlib calls (`XSync`, round-trip `XGetWindowProperty` per window in the recursive tree walk) via ctypes, so it inherits the same hang mode. `apply_layout`, `_reflow_layout`, `_poll_for_window` (every 0.5 s), the title-keeper and the map-keeper all sit on it. The Python `signal` import (L91) suggests an alarm was intended and never wired.
- **Failure scenario:** XWayland stalls (gamescope reset mid-reflow, the documented "gamescope reset" in kwin_positioner L217): `dex_list_windows` in `apply_layout` blocks forever → `_reflow_layout` never returns → the FIFO event loop is stuck (PRINCIPLES #10: one handler at a time) → no further CONTROLLER_ADD/REMOVE/SLOT_DIED processing; watchdog `_check_slot_window` (`dex_list_windows`, watchdog L85) also hangs.
- **Fix:** In `_dex_run`: `timeout --foreground "${DEX_TIMEOUT_S:-5}" python3 "$DEX_PY_SCRIPT" "$@"` (named constant, module header). In the backend: `signal.alarm(int(os.environ.get('DEX_ALARM_S','5')))` before dispatch and `_lib.XSetIOErrorHandler` so a dead display exits instead of hanging. Callers already tolerate non-zero exits.

### E7. `add-to-steam.py` derives the next shortcut index with a raw-bytes regex — any digit-only string value or int with a digit byte pattern yields a wrong / duplicate index
- **Severity:** Medium
- **Category:** bug / robustness
- **File:** `add-to-steam.py:100-111`
- **Status:** CONFIRMED
- **What:**
  ```python
  matches = re.findall(rb'\x00(\d+)\x00', data)
  if matches: return int(matches[-1])
  ```
  Entry keys are `\x00<idx>\x00`, but the same byte shape occurs (a) for any
  string value consisting only of digits (`\x01LaunchOptions\x00` + `1` +
  `\x00`, an appname like `2048`), and (b) for any `T_INT` whose low byte is
  `0x30–0x39` and second byte `0x00` (the preceding key's NUL + digit + NUL),
  e.g. `appid` bytes `… 00 31 00 80`. The code also takes the *last* match in
  file order, not the maximum. `remove-from-steam.py` was written precisely
  because "a byte-splice that guesses wrong does not fail loudly, it silently
  corrupts the file" (its header L7-18), yet its inverse still guesses.
- **Failure scenario:** Existing library: entry 0 "RetroArch", entry 1 "2048"
  (appname `2048`, the last entry). `matches[-1]` is `2048` → new index
  `2049`. Or entry 1 has `LaunchOptions` `"1"` → last match `1` → new index
  `2` when an index 2 already exists → duplicate key; Steam drops or merges
  one of them (the user's, or ours — and then `remove-from-steam.py`'s
  renumbering hides the evidence).
- **Fix:** Parse the file with the same `parse_map` the remover already has
  (share it as a tiny `mcss_vdf.py`, or copy with a `# PAIRED WITH
  remove-from-steam.py` comment per ARCHITECTURE §1), and compute
  `index = max(int(k) for _, k, _ in shortcuts if k.isdigit()) + 1`. That
  also gives add-to-steam the round-trip guard and a real duplicate check
  (E11).

### E8. `shortcuts.vdf` is rewritten in place (truncate-then-write) in both scripts; `add-to-steam.py` makes no backup of its own
- **Severity:** Medium
- **Category:** robustness (data loss)
- **File:** `add-to-steam.py:143-146`, `remove-from-steam.py:275-279`
- **Status:** CONFIRMED
- **What:** `with open(shortcuts_file, "wb") as f: f.write(new_data)` — `open(…, "wb")` truncates first; a crash, SIGTERM (the installer is often run over SSH and `add-to-steam.py`'s stderr is thrown away by `system_integration.sh:291`), or ENOSPC between truncate and write leaves an empty/partial file holding *every* non-Steam shortcut the user owns. The remover at least copies a `.mcss-backup-<ts>` first (L275-276) but then does the same in-place write. The only backup on the add side is the installer's optional `tar cJf "$PWD/…"` (E18), which is skipped with a warning when it fails.
- **Failure scenario:** Deck's home partition is full (common after Java/Minecraft downloads) → `open("wb")` truncates to 0 bytes → `f.write` raises ENOSPC → shortcuts.vdf is 0 bytes → Steam starts with an empty library of non-Steam games.
- **Fix:** Write to `shortcuts_file + ".tmp"` in the same directory, `f.flush(); os.fsync(f.fileno())`, then `os.replace(tmp, shortcuts_file)` (STYLE-GUIDE §7.9 "atomic writes via tmp + mv"). Do it in both scripts, and have add-to-steam create the same timestamped `.mcss-backup-` file the remover uses (one naming, #9).

### E9. `system_integration.sh` uses `pkill -x steam` (a name-matched kill) and `steam -shutdown`, which `remove-from-steam.py` in the same repo documents as having wedged Game Mode
- **Severity:** Medium
- **Category:** principle-violation (#7) / logic
- **File:** `modules/system_integration.sh:149`, `:155`; contrast `remove-from-steam.py:20-23`, `:304-305`
- **Status:** CONFIRMED
- **What:** `steam -shutdown 2>/dev/null || true; sleep …; pkill -x "steam" 2>/dev/null || true`. PRINCIPLES #7 / CLAUDE.md non-negotiable: "no `pkill`/`killall`/name-matched kills". The remover's header says "Never restart Steam for the user — a remote `steam -shutdown` has wedged Game Mode before" and refuses with exit 2 when Steam is running; the adder's wrapper does the opposite, unconditionally, three seconds apart, after a single `pgrep -x steam`. The two halves of the "paired inverse" disagree on the one destructive step.
- **Failure scenario:** Installer run from a Konsole inside Game Mode (or over SSH while the Deck sits in Game Mode): `steam -shutdown` + `pkill -x steam` takes down the Steam client that owns the gamescope session → the user's session ends mid-install (the exact HW incident the remover cites). Also, `pkill -x steam` matches any process whose comm is `steam` — including a second user's client on a shared desktop box.
- **Fix:** Mirror the remover: detect (via `/proc/*/comm`, as `steam_is_running()` does), and if Steam is running either refuse with a clear message or ask the user to close it themselves; never signal. If a kill must stay, it has to be the PID from `~/.steam/steam.pid` only (a tracked PID, not a name match), behind an explicit prompt.

### E10. `remove-from-steam.py` `is_ours` "exe under --target-dir" rule deletes any shortcut whose exe lives under `~/.local/share/PolyMC` — including a user's own PolyMC.AppImage shortcut
- **Severity:** Medium
- **Category:** logic (over-broad match, data loss)
- **File:** `remove-from-steam.py:140-157` (`:155`), caller `uninstall-minecraft-splitscreen.sh:430` (`--target-dir "$TARGET_DIR"`), `install-minecraft-splitscreen.sh:334` (`TARGET_DIR="$HOME/.local/share/PolyMC"`)
- **Status:** CONFIRMED (code); user impact PLAUSIBLE
- **What:** The docstring promises "Deliberately conservative … A shortcut the user made themselves … must survive", but the third rule is `if target_dir and exe_s.startswith(target_dir.rstrip("/") + "/"): return True`. `TARGET_DIR` is the PolyMC data root, and `launcher_setup.sh` installs `PolyMC.AppImage` there (`add-to-steam.py:46` even probes `~/.local/share/PolyMC/PolyMC.AppImage`). A user who added plain PolyMC (or any tool they dropped under that dir) to Steam has an exe under `TARGET_DIR/`. `tests/test_uninstall_purge.sh:_fake_steam` only uses foreign exes in `/usr/bin`, so T4.2 "foreign shortcuts survive" cannot catch this.
- **Failure scenario:** Steam library has "PolyMC" → `/home/deck/.local/share/PolyMC/PolyMC.AppImage`. `uninstall-minecraft-splitscreen.sh` (even without `--purge`) → `remove-from-steam.py --target-dir /home/deck/.local/share/PolyMC` → the PolyMC shortcut and its artwork are removed and the file renumbered, reported as "removing shortcut: PolyMC".
- **Fix:** Drop rule 3, or narrow it to `exe_s == os.path.join(target_dir, LAUNCHER_BASENAME)`; rules 1–2 already cover every shortcut `add-to-steam.py` can write. Add a fixture entry `("PolyMC", f"{TARGET_DIR}/PolyMC.AppImage")` to `_fake_steam` and assert it survives (mutation-test by re-adding rule 3).

## Low

### E11. Installer-side duplicate detection is a second encoding of `TARGET_DIR` and disagrees with what `add-to-steam.py` writes and where it looks
- **Severity:** Low
- **Category:** hardcoded / contract mismatch
- **File:** `modules/system_integration.sh:114`, `:125`; `add-to-steam.py:83-84`; `remove-from-steam.py:187-199`
- **Status:** CONFIRMED
- **What:** `local launcher_path="local/share/PolyMC/minecraft"` then `grep -q "$launcher_path" ~/.steam/steam/userdata/*/config/shortcuts.vdf`. The actual `exe` written is `"$MCSS_TARGET_DIR/minecraftSplitscreen.sh"` (add-to-steam L30); the fragment only matches because `TARGET_DIR` happens to be `$HOME/.local/share/PolyMC` today — ARCHITECTURE §1 requires such copies to carry `# PAIRED WITH`. The adder itself has no duplicate check and picks `next(d for d in os.listdir(userdata) if d.isdigit())` — an *unordered* first user — while the installer greps all users and the remover iterates all users (sorted). A user's own PolyMC shortcut also contains `local/share/PolyMC/minecraft`? No — but `…/PolyMC/minecraft` also matches a hypothetical `~/.local/share/PolyMC/minecraft-launcher` shortcut, suppressing our add.
- **Failure scenario:** Two Steam accounts on one Deck (family sharing): user A already has our shortcut (grep matches, installer says "already present"); user B, who `os.listdir` would have returned first, never gets one. Conversely, relocating `TARGET_DIR` (a documented aim of D16/#45) makes the grep never match and every re-install appends a duplicate.
- **Fix:** Move the duplicate check into `add-to-steam.py` using the real parser (E7) and `is_ours`'s rules, iterate every userdata id (or take `--steam-user`), and delete the bash-side fragment. Until then add the `# PAIRED WITH add-to-steam.py detect_launcher()` comment.

### E12. `_get_wid_from_state`'s dex fallback can return several WIDs (no `head -1`), which then fail `int()` in the backend
- **Severity:** Low
- **Category:** bug
- **File:** `modules/window_manager.sh:149`; contrast `modules/instance_lifecycle.sh:698` (`| head -1`), `:713` (`| tail -1`)
- **Status:** PLAUSIBLE (needs two windows whose name contains `SplitscreenP<n>`, e.g. a not-yet-reaped previous instance in the same slot, or PolyMC's log window renamed by the title-keeper)
- **What:** `wid=$(dex_search --name "${MCSS_WINDOW_TITLE_PREFIX}${slot}" 2>/dev/null || true)` keeps every line. `action_search_name` is a substring match over the whole tree. A multi-line `$wid` is then passed as one argument to `dex_move_resize_remap "$wid" …` → Python `int("123\n456")` → `ValueError` → exit 2 → empty readback → "dex remap FAILED" → `return 1` → E2/E3.
- **Fix:** `| head -1` (as `_poll_for_window` does), and make dex's search prefer exact-name matches.

### E13. dex backend rejects hex window ids although both callers' docs say WIDs may be hex
- **Severity:** Low
- **Category:** contract mismatch
- **File:** `modules/dex.sh:282`, `:380`, `:412`, `:453`, `:465` (`int(args[0])`); docs `modules/window_manager.sh:57` ("WID (decimal or hex)"), `modules/instance_lifecycle.sh:152` ("wid field holds the X11 window ID (hex integer)")
- **Status:** CONFIRMED
- **What:** `int("0x4a00003")` raises `ValueError` (caught by the dispatcher → exit 2, empty output). Today it works only because `dex_search` prints decimal and the state stores that decimal unquoted (`{"wid": ${window_id}}`). Anyone feeding a WID from `xprop`/`xwininfo` (hex) — e.g. the hardware probes — gets a silent no-op.
- **Fix:** `int(args[0], 0)` everywhere a WID is parsed (accepts `0x…` and decimal), or fix the two comments to say "decimal".

### E14. dex backend falls back to a predictable, executed path in world-writable `/tmp`; `mv -f` onto a foreign-owned file there aborts the launcher at source time
- **Severity:** Low
- **Category:** security / robustness
- **File:** `modules/dex.sh:66` (`DEX_PY_SCRIPT="${DEX_PY_SCRIPT:-${XDG_RUNTIME_DIR:-/tmp}/dex_backend_${UID}.py}"`), `:516` (`mv -f "$_tmp" "$DEX_PY_SCRIPT"`), `:522` (unconditional source-time call), `:533` (`[[ -f "$DEX_PY_SCRIPT" ]] || _dex_generate_backend`), stale comment `:600` ("per-PID path under /tmp")
- **Status:** CONFIRMED (code); attack PLAUSIBLE (needs another local user)
- **What:** The generated backend is `python3`-executed on every dex call. When `XDG_RUNTIME_DIR` is unset the path is `/tmp/dex_backend_1000.py`. If another local user pre-creates that name, `mv -f` over it fails (sticky-bit `/tmp` forbids replacing another user's file) → `_dex_generate_backend` returns non-zero from a bare source-time call under `set -e` → sourcing `dex.sh` aborts the launcher. With `set -e` off, `_dex_run`'s `[[ -f … ]]` check would happily execute the foreign file. `runtime_context.sh` already provides `MCSS_HELPER_DIR` (0700) for "scripts that get EXECUTED" (kwin_positioner L157-159); dex is the grandfathered module that does not use it. [KNOWN: docs/BUG-AUDIT-2026-06-24-followup.md M7 / docs/TODO.md:154 flagged the `/tmp/dex_$$.py` cleanup aspect; the executed-in-/tmp and mv-failure aspects are new.]
- **Fix:** Resolve via `mcss_resolve_paths` and use `"$MCSS_HELPER_DIR/dex_backend.py"`; guard the source-time call (`_dex_generate_backend || echo "[dex] WARNING: …" >&2`); update the L600 comment.

### E15. Geometry cache defaults to predictable `/tmp/mcss-geom`, is read with `cat` to decide "skip repositioning", and its writer is a bare redirection under `set -e`
- **Severity:** Low
- **Category:** security / robustness
- **File:** `modules/window_manager.sh:352-361`; default in `modules/runtime_context.sh:327` (`MCSS_GEOM_DIR="${MCSS_GEOM_DIR:-/tmp/mcss-geom}"`); duplicated literal `modules/instance_lifecycle.sh:173`, `:1198` (`${MCSS_GEOM_DIR:-/tmp/mcss-geom}` — consumer-side fallback, ARCHITECTURE §3 corollary)
- **Status:** CONFIRMED
- **What:** A pre-existing `/tmp/mcss-geom/slot1` (any local user, or a stale one from a different session — #172 fixed only the same-user stale case) equal to the signature makes `apply_layout` `continue` without positioning. `mkdir -p "$_gd" 2>/dev/null; printf '%s' "$_sig" > "$_gf" 2>/dev/null` — if the dir exists but is not ours, `printf`'s redirection fails → errexit (E2 class).
- **Fix:** Default `MCSS_GEOM_DIR` to `$MCSS_HELPER_DIR/geom` in runtime_context; remove the two `:-/tmp/mcss-geom` re-embeds in instance_lifecycle; `|| true` on the cache write with a comment.

### E16. `compute_slot_geometry` re-embeds the 1280/800 screen fallback
- **Severity:** Low
- **Category:** hardcoded
- **File:** `modules/window_manager.sh:251-252` (`${3:-${MCSS_SCREEN_W:-1280}}`, `${4:-${MCSS_SCREEN_H:-800}}`); canonical `modules/runtime_context.sh:637-638`; same pattern `modules/orchestrator.sh:321`
- **Status:** CONFIRMED
- **What:** ARCHITECTURE §3: "consumers use bare `$NAME` (a consumer-side `:-fallback` re-embeds the literal — the 1280/800 … drift pattern)". `apply_layout` already calls `mcss_resolve_screen` when dimensions are missing; the pure function should require its args.
- **Fix:** `local screen_w="${3:?screen_w required}"` (or `${3:-$MCSS_SCREEN_W}` with no literal) and keep the fallback only in `mcss_resolve_screen`.

### E17. Unnamed `sleep 0.2` settle delays in kwin_positioner
- **Severity:** Low
- **Category:** hardcoded
- **File:** `modules/kwin_positioner.sh:250`, `:308`
- **Status:** CONFIRMED
- **What:** "Let run() apply the geometry before we unload" — a timing constant that decides whether the placement is aborted, duplicated in two functions, with no `_S` name (ARCHITECTURE §3 "Sleep/timeout/retry values always get `_S` names", #86 backlog).
- **Fix:** `readonly KWIN_POSITIONER_RUN_SETTLE_S=0.2` in a guarded constants block; use in both sites.

### E18. Shortcuts backup lands in `$PWD` (arbitrary under `curl | bash`), and is silently skipped on failure
- **Severity:** Low
- **Category:** robustness
- **File:** `modules/system_integration.sh:213`, `:222-227`
- **Status:** CONFIRMED
- **What:** `local backup_path="$PWD/steam-shortcuts-backup-$(date …).tar.xz"` (also shellcheck SC2155). Under the documented `curl | bash` install `$PWD` is wherever the shell was — `/`, a read-only mount, or the Deck's SD card — and `tar` failure only prints "proceeding without backup". Combined with E8 that leaves no copy at all. The comment claims `$PWD` is "safer than TARGET_DIR which may be cleaned", but #41 moved other artefacts *into* `TARGET_DIR` for hygiene.
- **Fix:** Write the backup next to the file as `shortcuts.vdf.mcss-backup-<ts>` (the remover's convention, one naming) and make a failed backup abort the Steam step rather than proceed.

### E19. `.desktop` `Exec=` is the unquoted launcher path
- **Severity:** Low
- **Category:** bug
- **File:** `modules/system_integration.sh:488` (`Exec=$launcher_script_path`), path from `:458`
- **Status:** CONFIRMED
- **What:** Desktop Entry spec requires quoting when the path contains spaces/reserved chars; `TARGET_DIR="$HOME/.local/share/PolyMC"` inherits `$HOME`. The same unquoted path goes into Steam's `exe` field (`add-to-steam.py:131`), where Steam itself stores `"quoted"` exes (the remover's `strip('"')` shows it expects both).
- **Fix:** `Exec="$launcher_script_path"` in the heredoc; in add-to-steam write `f'"{exe}"'` (and keep the crc input consistent with what is stored).

### E20. `add-to-steam.py` robustness gaps: missing-userdata traceback, no `config/` dir creation, unbounded `urlopen`, `.jpg` saved as `.png`
- **Severity:** Low
- **Category:** robustness / principle-violation (#6)
- **File:** `add-to-steam.py:84`, `:92-94`, `:158`, `:164-166`
- **Status:** CONFIRMED
- **What:** `os.listdir(userdata)` raises `FileNotFoundError` when Steam has never run (uncaught; the installer hides it behind `2>/dev/null` and prints "encountered errors"). `open(shortcuts_file, "wb")` assumes `config/` exists. `urllib.request.urlopen(req)` has no timeout — five sequential downloads can each hang the installer indefinitely (PRINCIPLES #6). `path = … f"{appid}{suffix}.png" if not url.endswith(".ico")` stores the JPEG main grid as `<appid>.png`. Because the remover's pattern accepts `png|jpg|ico` this stays paired, but Steam sniffs content so it is merely misleading.
- **Fix:** `os.makedirs(config_dir, exist_ok=True)`; wrap the userdata lookup in a clear error; `urlopen(req, timeout=15)` (match `fetch_url`'s 15 s); derive the extension from the URL.

### E21. `remove-from-steam.py` parser raises `ValueError`/`struct.error` on truncated input, bypassing the `VdfError` reporting path
- **Severity:** Low
- **Category:** robustness
- **File:** `remove-from-steam.py:58` (`data.index(b"\x00", i)` → `ValueError`), `:84` (`struct.unpack("<I", data[i:i+4])` → `struct.error`), handler `:313` (`except (VdfError, OSError)`)
- **Status:** CONFIRMED
- **What:** A file cut mid-string or mid-int gives a Python traceback instead of "ERROR on <path>: …". Still fail-safe (nothing has been written, exit status non-zero), so this is presentation only — but the uninstaller's `if python3 "$helper"` reports it as a failure without the manual-removal hint.
- **Fix:** In `_read_cstr` catch `ValueError` → `raise VdfError("unterminated string at offset …")`; bounds-check before `unpack`; add `except Exception` fallback in `main` that prints the same "refusing to modify" line.

## Info

### E22. dex `get_prop` computes format-32 property length with a 4-byte stride, leaks `prop` when `nitems == 0`, and assumes little-endian
- **Severity:** Info
- **Category:** bug (latent)
- **File:** `modules/dex.sh:194-201` (`result = bytes(data_ptr[:n * fmt // 8])`, `if status != 0 or not prop or not nitems.value: return None` before `XFree`), `:244-248` (`struct.unpack('<I', prop[:4])`)
- **Status:** CONFIRMED
- **What:** Xlib returns format-32 data as an array of C `long` (8 bytes each on x86_64 — the module's own N9 comment at L205-208 says so for the *write* side). `n * 4` bytes is only correct for `n == 1`; the sole format-32 read today is `_NET_WM_PID` (n = 1), so it works by coincidence. A multi-element format-32 read (e.g. `_NET_WM_STATE`) would return interleaved garbage. `XFree(prop)` is skipped on the early-return path (Xlib allocates even for empty results). `'<I'` should be native `'=I'`/`'@I'`.
- **Fix:** `stride = 8 if fmt == 32 else fmt // 8; result = bytes(data_ptr[:n * stride])`, then re-pack per element; move `XFree` to a `finally`.

### E23. dex `action_is_viewable`'s "gone" branch is unreachable (default Xlib error handler `exit(1)`s on BadWindow); the shell wrapper's `|| echo gone` is what actually implements the contract
- **Severity:** Info
- **Category:** dead-code / documentation
- **File:** `modules/dex.sh:454-457`; consumer `modules/instance_lifecycle.sh:1152`
- **Status:** CONFIRMED (Xlib semantics: `_XReply` → `_XError` → `_XDefaultError` → `exit(1)` for BadWindow; no `XSetErrorHandler` anywhere in the backend)
- **What:** The docstring says "XGetWindowAttributes failed → window destroyed" and prints "gone", but a destroyed window produces an X protocol error, the default handler prints "X Error of failed request: BadWindow" to stderr and exits the interpreter; the `== 0` branch never runs. Same for `action_getgeometry`. Functionally fine today only because every caller does `… 2>/dev/null || echo gone`/`|| echo ""`.
- **Fix:** Install a no-op `XSetErrorHandler` (ctypes `CFUNCTYPE`) so the documented return paths are real, or delete the dead branch and document the exit-code contract.

### E24. Stale documentation and misleading log tags in window_manager
- **Severity:** Info
- **Category:** documentation
- **File:** `modules/window_manager.sh:7-8` ("applies layout via xdotool. Maintains black placeholder windows" — both removed 2026-06-23 per L98-102 and L389), `:362` (`echo "[orchestrator] WINDOW … [kwin frameGeometry]" >&2` emitted from window_manager even when the dex override-redirect path — the PRIMARY path since 2026-06-27 — was used), `:11-13` (Public API omits `sync_apply_layout` and the return contracts)
- **Status:** CONFIRMED
- **Fix:** Rewrite the header; prefix the line `[window_manager]` and tag the path actually taken (`_position_slot` knows it).

### E25. Installer discards `add-to-steam.py`'s stderr and executes a freshly downloaded script without an integrity check
- **Severity:** Info
- **Category:** robustness / security (accepted trust model)
- **File:** `modules/system_integration.sh:264-268`, `:291`
- **Status:** CONFIRMED
- **What:** `python3 "$steam_script_temp" 2>/dev/null` hides every traceback (E20's failures show up only as "encountered errors … common causes: PolyMC not found"). The `fetch_url "${MCSS_REPO_RAW_URL}/add-to-steam.py"` fallback runs whatever `main` currently serves, over HTTPS but with no pin/hash — identical to the installer's own `curl | bash` model, so not a new exposure, but the same trust decision is now made in three places (installer bootstrap, here, `uninstall-minecraft-splitscreen.sh:421`).
- **Fix:** Capture stderr to the install log (`2>>"$LOG"`) and surface the last lines on failure; consider pinning `MCSS_REPO_RAW_URL` to a tag/commit for the helper fetches.

### E26. `add-to-steam.py` appid comment ("matches Steam's logic") is inaccurate, and the VDF entry writer now exists in three copies
- **Severity:** Info
- **Category:** documentation / hardcoded (duplication)
- **File:** `add-to-steam.py:138-139` (`crc32((APPNAME + EXE))`; Steam's documented input is `exe + appname`), `:114-136` (`make_entry`), `tests/test_uninstall_purge.sh:84-94` (private copy, no `# PAIRED` comment), `remove-from-steam.py:91-104` (`serialize_map`, the canonical inverse)
- **Status:** CONFIRMED
- **What:** Because the appid is stored explicitly in the entry and the remover reads it back (`_field(body, "appid")`), the pair stays consistent regardless of the crc input order — but the comment invites someone to "fix" one side. The entry byte layout (`\x02appid`, `\x01appname`, `\x01exe`, `\x01StartDir`, `\x01LaunchOptions`, `\x01icon`) is encoded by hand in the adder and again in the test fixture; a field added in one is invisible to the other (#9).
- **Fix:** Correct the comment; have the test import `make_entry` from `add-to-steam.py` (or a shared `mcss_vdf.py`, see E7).

### E27. Cross-module (outside assigned files, noted while tracing): spawn_instance's background keepers inherit the capture pipe in the orchestrator's no-mktemp fallback
- **Severity:** Info
- **Category:** principle-violation (#8)
- **File:** `modules/instance_lifecycle.sh:1114-1123` (title-keeper `( … ) &`), `:1148-1160` (map-keeper `( … ) &`), `modules/orchestrator.sh:460` (`spawn_instance … 2>&1 | sed …` fallback when `mktemp` fails)
- **Status:** PLAUSIBLE (only in the `_si_log=""` branch)
- **What:** Both keepers are backgrounded without `>/dev/null 2>&1`; in the mktemp-failed branch they inherit the `| sed` pipe, so `sed` (and the brace group) cannot finish until the 90 s map-keeper exits — the #80/#103 pattern. In the normal branch they hold an fd to the deleted `$_si_log`, which is harmless. Flagged for the owner of those files.

---

## Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 3 (E1–E3) |
| Medium | 7 (E4–E10) |
| Low | 11 (E11–E21) |
| Info | 6 (E22–E27) |

**Top 3:**

1. **E1** — `dex.sh`'s `XWindowAttributes` layout omits `colormap` before
   `map_installed`, so `map_state` reads the colormap XID; `dex_is_viewable`
   effectively always says "unmapped" and the #57 map-keeper re-maps/raises
   blindly 45× per slot. Verified against `/usr/include/X11/Xlib.h` on this
   host (offset 80 vs 92).
2. **E2** — `apply_layout` calls `_position_slot`, `kwin_place_windows` and a
   `dex_list_windows | while` pipeline bare under `set -euo pipefail`; a
   positioning failure kills the backgrounded `spawn_instance` group before
   the map-keeper, the post-spawn reflow, the slot-release branch, and before
   the spawn log is echoed (its EXIT trap deletes it). Reproduced with a
   minimal bash script.
3. **E3 / E9 / E10** (tie) — `apply_layout` never returns non-zero, so the
   orchestrator's H10 reflow-retry is dead; and on the Steam side the adder
   still does `steam -shutdown` + `pkill -x steam` (PRINCIPLES #7, and the
   remover's own header warns this wedged Game Mode) while the remover's
   `--target-dir` rule will delete a user's own PolyMC shortcut on uninstall.
