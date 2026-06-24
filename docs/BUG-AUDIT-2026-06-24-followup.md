# Minecraft Splitscreen — Follow-up Code Audit (2026-06-24)

> **Branch:** `feat/gamescope-windowing`
> **Scope:** Runtime orchestration + windowing rewrite (entry launcher, orchestrator,
> controller monitor, instance lifecycle, window manager / kwin positioner / dex,
> dock detection, watchdog, preflight) plus install-flow carry-over.
> **Method:** 4 parallel module reviewers + line-by-line verification of
> `orchestrator.sh` and the two highest-impact `dex.sh` claims.
> **Relationship to prior audit:** This is a follow-up to `BUG-AUDIT-2026-06-23.md`,
> which claimed "ALL 27 ADDRESSED IN CODE." This document records (a) which of those
> fixes actually landed and (b) new defects the rewrite introduced.

---

## Executive summary

The rewrite is real progress. Two notable improvements over `main`:

- The `FlyingEwok` wrong-repo download URLs are **gone** on this branch.
- The risky GitHub self-update in the launcher is **gone**.

However:

- The "all 27 fixed" status is **optimistic** — **H8, H9, H10, L3, M7 are only
  partial.**
- The new event loop + `dex` X11 backend introduce a fresh layer of defects the prior
  audit did not cover: **leaked player slots, double-spawns, orphaned processes,
  non-functional EWMH state, controller-mask gaps, and two local-privilege `/tmp`
  vectors.**
- The committed CurseForge `token.enc` + hard-coded passphrase persist (lower impact
  now that required mods moved to Modrinth, but still a committed secret).

**Fix priority:** (1) orchestrator slot-lifecycle trio, (2) entry-script `/tmp`+PATH
and systemd-env vectors, (3) controller-mask unpaired/own-node guard, (4) dex
EWMH/format-32 correctness.

---

## 1. Verification of the prior audit's "all fixed" claims

### Genuinely fixed (verified in current code)
C1 (4-field CONTROLLER_ADD parse), H1 (udevadm process-substitution), H2/H3 (dex arg
guards + active-wid length), H4/H5 (geometry single-read + validation), H7 (KWin pid
validation), H11/H12/H13 (poll constants, shadow var, `.files` primary selector),
H6/H14/L1 (FIFO `|| true`, awk field, watchdog trap), M1/M3/M4/M5/M6/L2.

### Overstated / not fully fixed
- **H8 — STILL-BROKEN at the second call site.** `kwin_positioner.sh:193`
  (`kwin_set_noborder`) still does `... loadScript | tr -dc '0-9'`, so `ERROR: 123`
  silently becomes script id `123`. Only the first call site was fixed.
- **H9 — PARTIAL.** Slot-liveness reaping (`_reap_dead_slots`) was added, but the
  promised monitor heartbeat (`kill -0` on the monitor PIDs) was never wired. If
  `controller_monitor` / `watchdog` / `dock_monitor` die, nothing notices — in docked
  mode no new controller can join and the loop times out forever
  (`orchestrator.sh:399-414`, `512-546`).
- **H10 — PARTIAL.** Reflow failure is now logged but the advertised `reflow_needed`
  retry flag was never implemented (`orchestrator.sh:255`).
- **L3 — PARTIAL.** jq `--arg` hygiene done in some files but not `dex.sh:595` /
  `window_manager.sh:183,195`; the "fail on unpaired mask arg" fix was not applied.
- **M7 — PARTIAL.** `dex` temp now prefers `$XDG_RUNTIME_DIR`, but still leaks
  `/tmp/dex_$$.py` with no trap when that var is unset.

---

## 2. New findings

### 🔴 High — runtime correctness

- **N1 — Leaked player slot on spawn failure.** `orchestrator.sh:210` reserves the
  slot synchronously (`{"active":true}`), then backgrounds `spawn_instance ... || true`
  (`:249`). On spawn failure the slot stays `active:true` forever, and
  `_reap_dead_slots` skips it (`:169`, "no bwrap_pid → still launching"). One of 4
  player slots is permanently dead. **Verified.**
  *Fix:* clear the reservation on spawn failure inside the background block.

- **N2 — Orphaned spawn subshells survive teardown.** The `{ ... } &` spawn blocks
  (`orchestrator.sh:241-256`) are never PID-tracked; `cleanup()` (`:616`) only kills
  the three monitors. A spawn polling up to 120s can map a window *after* teardown.
  *Fix:* track and kill these PIDs in `cleanup`.

- **N3 — Double-spawn on slot 1 (dock→handheld).** `_handle_msg` keeps slot 1 alive
  and returns 1 (`orchestrator.sh:307-331`); `main` then calls `handheld_flow`, which
  unconditionally `spawn_instance 1` (`:396`) over the survivor. **Verified.**
  *Fix:* guard with `slot_is_active 1`.

- **N4 — `set_fullscreen` / `set_skip_taskbar` are non-functional.** `dex.sh:428-449`
  write a single 32-bit element (`action`, i.e. 0/1) as the *entire* `_NET_WM_STATE`,
  replacing existing state; `state_atom` is never written (nelements=1), and the EWMH
  ClientMessage path `_send_client_msg` is a `pass` stub (`:426`). These calls corrupt
  window state instead of setting it. **Verified.**
  *Fix:* send a proper `_NET_WM_STATE` ClientMessage with SubstructureRedirect.

- **N5 — Controller mask: unpaired/own-node not guarded.** The bwrap mask loop
  (`instance_lifecycle.sh`, `while [[ $# -ge 2 ]]`) consumes `(event, js)` pairs but
  silently drops a trailing unpaired arg → that controller stays unmasked inside the
  sandbox → cross-slot input. Nothing prevents the slot's own node from being in the
  mask set → `--bind /dev/null` wins → slot loses its own controller.
  *Fix:* reject odd arg counts; exclude own node from the mask set.

### 🟠 High — security (entry script)

- **N6 — Predictable `/tmp` + `PATH=/tmp:$PATH`.** `minecraftSplitscreen.sh` writes
  `/tmp/kwin_wayland_wrapper` and prepends `/tmp` to PATH for the whole nested session
  (~`:417-423,582-587,627-632`). Any local user can pre-plant that file (or shadow any
  later command). Local code-execution / TOCTOU vector.
  *Fix:* `mktemp -d` 0700, reference by absolute path, don't prepend `/tmp`.

- **N7 — systemd env injection.** `_restore_session_env` reads
  `/tmp/splitscreen-session-env.bak` line-by-line into `systemctl --user
  set-environment` (~`:366,385-396`). A planted file injects env (e.g. `LD_PRELOAD`)
  into the user's systemd manager.
  *Fix:* use `$XDG_RUNTIME_DIR`; validate each line matches `^[A-Z_]+=`.

### 🟡 Medium

- **N8 — `dex_spawn_placeholder` → "Unknown action".** `dex.sh:586-588` dispatches
  `spawn_placeholder`, which isn't in `ACTIONS` (`:495-516`). Dead/stale API that
  errors if ever called. **Verified.** *Fix:* delete it (placeholders were removed) or
  implement the handler.

- **N9 — Format-32 property writes use 4-byte stride.** `change_prop32` / `get_prop`
  pass `c_uint32` arrays for `XChangeProperty(...,32,...)`, but Xlib treats format-32
  data as C `long` (8 bytes on 64-bit). `set_decorations` (`dex.sh:491`, nelements=5)
  over-reads 20 bytes past the buffer and lands the "decorated" bit in the wrong MWM
  field → borderless is unreliable/garbage on 64-bit. *Fix:* use `c_long` arrays.

- **N10 — KWin PID-only window match.** `kwin_positioner.sh:118` matches purely by PID;
  Minecraft's launcher+JVM or a splash window sharing the PID gets mis-positioned.
  *Fix:* add a caption / `resourceClass` cross-check.

- **N11 — No post-launch bwrap liveness check.** `instance_lifecycle.sh` records
  `bwrap_pid` then polls Java for 60s; a bwrap that dies instantly (bad arg) burns the
  full timeout. *Fix:* `kill -0` right after launch.

- **N12 — Mod filename path traversal.** `instance_creation.sh:464` only replaces
  spaces; a mod title with `/` or `..` escapes `mods_dir` on `wget -O`. *Fix:* sanitize
  to `[A-Za-z0-9._-]`.

- **N13 — `cp -r .../*` false failure.** `instance_creation.sh:477` mishandles an empty
  mod set (nullglob not set) and reports total failure on any single unreadable file.

- **N14 — inotifywait on sysfs misses hotplug.** `dock_detection.sh:238` watches
  connector subdirs that vanish on unplug (watch dropped); real dock events can be
  missed. *Fix:* watch the parent for `create`/`moved_to` and keep the poll fallback.

- **N15 — Leaked monitors survive teardown.** `inotifywait` / `watch_display_mode` can
  reparent and hold the FIFO write-end across runs. *Fix:* `pkill` them in cleanup.

- **N16 — controller_monitor enumeration race.** The diff query and the `prev_nodes`
  snapshot are separate live scans (`controller_monitor.sh` ~`:487` vs `:628`); a device
  appearing between them can double-add → double-spawn. *Fix:* capture once.

### 🔵 Low
- Resolution fallback `720` vs `800` inconsistency (`minecraftSplitscreen.sh:872`).
- `date +%s%N` non-GNU breakage in the monitor's millisecond clock.
- `bind` / `unbind` / `change` udev actions ignored by `controller_monitor`.
- `preflight.sh` omits `kwin_wayland_wrapper` / `inotifywait` from required checks.
- DEBUG_MODE temp files leak (`instance_creation.sh:351-364`).
- Predictable `/tmp/mcss_place_*.js` with no trap (`kwin_positioner.sh`).

---

## 3. Security carry-over from `main`

`token.enc` is still committed and decrypted with the hard-coded passphrase
`MinecraftSplitscreenSteamDeck2025` (7 sites in `mod_management.sh`). Impact is lower
on this branch because required mods moved to Modrinth (`mods.conf`), so CurseForge is
now only used for optional/custom mods — but it remains a committed secret that should
be rotated and removed.

---

## 4. Recommended fix order

1. **Orchestrator slot lifecycle** — N1 (leaked slot), N3 (double-spawn), N2 (orphan
   subshells). Contained, high-value, low-risk.
2. **Entry-script hardening** — N6 (`/tmp`+PATH), N7 (systemd env injection).
3. **Controller isolation** — N5 (unpaired / own-node mask guard).
4. **dex correctness** — N4 (EWMH state), N9 (format-32 stride), N8 (dead action).
5. **Finish the partial audit items** — H8 second site, H9 monitor heartbeat, L3
   `--arg` + unpaired-mask, M7 temp cleanup.
6. **Secret hygiene** — rotate the CurseForge key, stop committing `token.enc`.

---

_Follow-up audit, 2026-06-24. Verifies `BUG-AUDIT-2026-06-23.md` against current code
and adds 16 new findings (N1–N16). Items N1, N3, N4, N8 independently line-verified;
remainder from parallel module review._
