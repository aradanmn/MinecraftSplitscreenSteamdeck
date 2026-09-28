title: [F9-F22] Install / uninstall / deploy / system / CI — Low and Info findings (checklist)
severity: low
security: no
type: Task
related: none
---
- [ ] F9 — `REPO_REF` is interpolated into the fetch URL unvalidated (`..` reaches another repo)
- [ ] F10 — Bootstrap curl/wget have no timeouts
- [ ] F11 — Hard-coded `deck` / UID 1000 / `/home/deck` across `system/`
- [ ] F12 — Root-run hook writes a predictable `/tmp` stamp; unvalidated arithmetic; unbounded `/tmp` log
- [ ] F13 — `minecraftsplitscreen-test.sh`: hard-coded checkout path, unbounded `git pull` on every Steam launch
- [ ] F14 — Uninstaller's fetched helper cleanup matches `/tmp/*` (deletes a checkout's own helper; leaks under `TMPDIR`)
- [ ] F15 — `--keep-data` leaves `modules/`, `bin/`, `java/` behind; two phantom targets
- [ ] F16 — `deploy.sh`: non-atomic copies, hard-coded `--help` range, third env-var name, stamp failure reported as success
- [ ] F17 — CI/release hardening: shellcheck scope, `timeout-minutes`, `permissions:`, unpinned actions, double runs
- [ ] F18 (= C25) — Built-in mod defaults duplicate `mods.conf`; the README install path guarantees the duplicate is used
- [ ] F19 — curl|bash `SCRIPT_DIR` = CWD picks up a stray `modules/`; download loop leaks globals
- [ ] F20 — README claims that no longer match the code
- [ ] F21 — `system/…/install.sh` aborts without a session bus after a half install; no uninstall
- [ ] F22 — `.gitignore`: no action

## Summary
Fourteen Low/Info findings from the install/uninstall/deploy/system/CI review, grouped so they can be closed as a checklist. Each has a ready diff (every diff was generated against the current file, passes `bash -n`/`sh -n` or a YAML parse, and `git apply --check`s cleanly from the pristine repo root on its own — apply them one at a time, since several touch the same files) or a one-sentence fix where the change is editorial. The two with teeth: F14 was reproduced for real while drafting these issues (a checkout under `/tmp` loses `remove-from-steam.py` on the first `--purge`), and F17's widened `shellcheck -S error` gate was run over the whole proposed file set and is clean today, so it can be enabled without a cleanup pass.

### F9. `REPO_REF` unvalidated; curl squashes `..` so it can point at any GitHub repo
`install-minecraft-splitscreen.sh:109,115`. `REPO_REF=../../someone/otherrepo/main` makes every module/launcher/patch fetch come from a different repository while messages still say `aradanmn/…` (reproduced by the review: curl sends `GET /foo/bar/main/x`). Verified the regex accepts `main`, `feat/x`, `v1.2.5` and rejects `../../foo/bar/main`, `/abs`, `a b`.
```diff
--- a/install-minecraft-splitscreen.sh
+++ b/install-minecraft-splitscreen.sh
@@ -107,6 +107,14 @@
 #   REPO_REF=feat/gamescope-windowing ./install-minecraft-splitscreen.sh
 # Exported so every sourced module's download URL uses the same ref.
 export REPO_REF="${REPO_REF:-main}"
+# A ref is a git branch/tag/commit name — never a path. curl collapses `..`
+# segments, so `REPO_REF=../../other/repo/main` would fetch (and source)
+# every module from a different repository while the messages still name
+# aradanmn/MinecraftSplitscreenSteamdeck.
+if [[ ! "$REPO_REF" =~ ^[A-Za-z0-9._/-]+$ || "$REPO_REF" == *..* || "$REPO_REF" == /* ]]; then
+    echo "❌ Error: REPO_REF='$REPO_REF' is not a valid git ref name" >&2
+    exit 1
+fi
 
 # Single home for the repo's raw-content URL (D15/#45 PR 3): every file the
 # installer chain fetches (modules, launcher, accounts.json, add-to-steam.py)
```

### F10. Bootstrap downloads have no timeout
`install-minecraft-splitscreen.sh:199,214,275-277`. `fetch_url` (15 s) is not yet sourced, so the bootstrap carries its own bound, named once (PRINCIPLES #6).
```diff
--- a/install-minecraft-splitscreen.sh
+++ b/install-minecraft-splitscreen.sh
@@ -124,6 +124,12 @@
 # GitHub repository information (modify these URLs to match your actual repository)
 readonly REPO_BASE_URL="${MCSS_REPO_RAW_URL}/modules"
 
+# Bootstrap fetches run BEFORE utilities.sh (fetch_url, 15 s default) is
+# available, so they carry their own bound (PRINCIPLES #6): a stalled TCP
+# connection must fail, not hang the installer silently under -s.
+readonly BOOTSTRAP_CONNECT_TIMEOUT_S=10
+readonly BOOTSTRAP_MAX_TIME_S=60
+
 # Installer modules — sourced during installation to run the setup workflow.
 readonly INSTALLER_MODULE_FILES=(
     "utilities.sh"
@@ -196,7 +202,8 @@
         
         # Download the module file
         if command -v curl >/dev/null 2>&1; then
-            curl_output=$(curl -fsSL "$module_url" -o "$module_path" 2>&1)
+            curl_output=$(curl -fsSL --connect-timeout "$BOOTSTRAP_CONNECT_TIMEOUT_S" \
+                --max-time "$BOOTSTRAP_MAX_TIME_S" "$module_url" -o "$module_path" 2>&1)
             curl_exit_code=$?
             if [[ $curl_exit_code -eq 0 ]]; then
                 chmod +x "$module_path"
@@ -211,7 +218,8 @@
                 ((failed_count++))
             fi
         elif command -v wget >/dev/null 2>&1; then
-            wget_output=$(wget -q "$module_url" -O "$module_path" 2>&1)
+            wget_output=$(wget -q --timeout="$BOOTSTRAP_CONNECT_TIMEOUT_S" --tries=2 \
+                "$module_url" -O "$module_path" 2>&1)
             wget_exit_code=$?
             if [[ $wget_exit_code -eq 0 ]]; then
                 chmod +x "$module_path"
@@ -272,9 +280,11 @@
 else
     _manifest_url="$REPO_BASE_URL/$RUNTIME_MANIFEST_NAME"
     if command -v curl >/dev/null 2>&1; then
-        curl -fsSL "$_manifest_url" -o "$MODULES_DIR/$RUNTIME_MANIFEST_NAME" 2>/dev/null || true
+        curl -fsSL --connect-timeout "$BOOTSTRAP_CONNECT_TIMEOUT_S" --max-time "$BOOTSTRAP_MAX_TIME_S" \
+            "$_manifest_url" -o "$MODULES_DIR/$RUNTIME_MANIFEST_NAME" 2>/dev/null || true
     elif command -v wget >/dev/null 2>&1; then
-        wget -q "$_manifest_url" -O "$MODULES_DIR/$RUNTIME_MANIFEST_NAME" 2>/dev/null || true
+        wget -q --timeout="$BOOTSTRAP_CONNECT_TIMEOUT_S" --tries=2 \
+            "$_manifest_url" -O "$MODULES_DIR/$RUNTIME_MANIFEST_NAME" 2>/dev/null || true
     fi
 fi
 
```

### F11. Hard-coded `deck`, UID 1000, `/home/deck` in `system/`; `.service` copied verbatim into any `$HOME`
`resume-display-restore.service:12` points at `/home/deck/…` while `install.sh` installs into `$HOME`; on any other account the oneshot fails silently (`--no-block`). Use the `%h` specifier; derive the user/UID once in the two root-side hooks and from `id -u` in the user-side worker.
```diff
--- a/system/deck-display-fixes/resume-display-restore.service
+++ b/system/deck-display-fixes/resume-display-restore.service
@@ -9,4 +9,6 @@
 
 [Service]
 Type=oneshot
-ExecStart=/home/deck/.local/bin/resume-display-restore.sh
+# %h = the unit owner's $HOME (systemd specifier): install.sh copies this
+# unit into ANY $HOME/.config/systemd/user, not only /home/deck.
+ExecStart=%h/.local/bin/resume-display-restore.sh
--- a/system/deck-display-fixes/dock-display-hotplug.sh
+++ b/system/deck-display-fixes/dock-display-hotplug.sh
@@ -52,9 +52,11 @@
 # Clear any stale WAYLAND_DISPLAY/DISPLAY/XAUTHORITY before restarting.
 # A leaked WAYLAND_DISPLAY forces gamescope into the nested backend and
 # crash-loops it (ValveSoftware/SteamOS#2467).
-su -s /bin/bash deck -c \
-    "XDG_RUNTIME_DIR=/run/user/1000 \
-     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
+DECK_USER="${DECK_USER:-deck}"
+DECK_UID="$(id -u "$DECK_USER" 2>/dev/null || echo 1000)"
+su -s /bin/bash "$DECK_USER" -c \
+    "XDG_RUNTIME_DIR=/run/user/$DECK_UID \
+     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DECK_UID/bus \
      systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY; \
      systemctl --user restart gamescope-session.target" 2>/dev/null || true
 
--- a/system/deck-display-fixes/resume-display-restore.sh
+++ b/system/deck-display-fixes/resume-display-restore.sh
@@ -13,8 +13,9 @@
 #
 # Set RESUME_RESTORE_DRYRUN=1 to log decisions without touching gamescope.
 
-export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
-export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/1000/bus}"
+_uid="$(id -u)"
+export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$_uid}"
+export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$_uid/bus}"
 
 LOG=/tmp/resume-display-restore.log
 log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
--- a/system/deck-display-fixes/deck-display-resume.sh
+++ b/system/deck-display-fixes/deck-display-resume.sh
@@ -13,9 +13,11 @@
 
 [ "$1" = "post" ] || exit 0
 
-su -s /bin/bash deck -c \
-    "XDG_RUNTIME_DIR=/run/user/1000 \
-     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
+DECK_USER="${DECK_USER:-deck}"
+DECK_UID="$(id -u "$DECK_USER" 2>/dev/null || echo 1000)"
+su -s /bin/bash "$DECK_USER" -c \
+    "XDG_RUNTIME_DIR=/run/user/$DECK_UID \
+     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DECK_UID/bus \
      systemctl --user start --no-block resume-display-restore.service" \
     >/dev/null 2>&1 || true
 
```

### F12. Predictable `/tmp` stamp written as root; unvalidated arithmetic; unbounded `/tmp` log
`dock-display-hotplug.sh:17,21-23,50`, `resume-display-restore.sh:19`. Root follows a symlink planted in `/tmp` (`ln -s /etc/shadow /tmp/gamescope-hotplug-restart-stamp`); non-numeric stamp content is an arithmetic error that falls through to the restart. Use root-only `/run`, validate, log to the journal.
````diff
--- a/system/deck-display-fixes/dock-display-hotplug.sh
+++ b/system/deck-display-fixes/dock-display-hotplug.sh
@@ -14,11 +14,14 @@
 # A 60s cooldown stamp prevents rapid-fire restarts during repeated reconnects.
 
 MAX_WAIT=45
-STAMP=/tmp/gamescope-hotplug-restart-stamp
+# /run is root-only tmpfs: this script runs as root, and a stamp in
+# world-writable /tmp could be pre-planted as a symlink to any file.
+STAMP=/run/gamescope-hotplug-restart-stamp
 
 # Cooldown check — bail if we restarted within the last 60s.
 if [ -f "$STAMP" ]; then
     last=$(cat "$STAMP" 2>/dev/null || echo 0)
+    case "$last" in *[!0-9]*|"") last=0 ;; esac   # never arithmetic on junk
     now=$(date +%s)
     [ $(( now - last )) -lt 60 ] && exit 0
 fi
--- a/system/deck-display-fixes/resume-display-restore.sh
+++ b/system/deck-display-fixes/resume-display-restore.sh
@@ -16,8 +16,9 @@
 export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
 export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/1000/bus}"
 
-LOG=/tmp/resume-display-restore.log
-log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
+# Journal, not an unbounded /tmp file: read it with
+#   journalctl --user -t resume-display-restore
+log() { logger -t resume-display-restore -- "$*" 2>/dev/null || echo "$*" >&2; }
 
 DRYRUN="${RESUME_RESTORE_DRYRUN:-0}"
 
--- a/system/deck-display-fixes/install.sh
+++ b/system/deck-display-fixes/install.sh
@@ -24,4 +24,4 @@
 echo " - resume worker:   $USER_BIN/resume-display-restore.sh (oneshot, on-demand)"
 echo " - resume trigger:  /etc/systemd/system-sleep/deck-display-resume.sh (fires on resume)"
 echo " - dock hotplug:    $USER_BIN/dock-display-hotplug.sh (env-sanitize added)"
-echo "Test (no gamescope restart):  RESUME_RESTORE_DRYRUN=1 $USER_BIN/resume-display-restore.sh && cat /tmp/resume-display-restore.log"
+echo "Test (no gamescope restart):  RESUME_RESTORE_DRYRUN=1 $USER_BIN/resume-display-restore.sh && journalctl --user -t resume-display-restore -n 20"
--- a/system/deck-display-fixes/README.md
+++ b/system/deck-display-fixes/README.md
@@ -44,5 +44,5 @@
 
 ```sh
 RESUME_RESTORE_DRYRUN=1 ~/.local/bin/resume-display-restore.sh
-cat /tmp/resume-display-restore.log
+journalctl --user -t resume-display-restore -n 20
 ```
````

### F13. `minecraftsplitscreen-test.sh`: hard-coded checkout path and an unbounded `git pull` on every Steam launch
`minecraftsplitscreen-test.sh:7,10`. Offline Deck → Steam shows "running" with nothing on screen until the TCP timeout; `|| true` also hides a failed `cd`, after which `exec` fails with a bare "No such file". Contradicts README §Developing ("git pull is not a deploy").
```diff
--- a/minecraftsplitscreen-test.sh
+++ b/minecraftsplitscreen-test.sh
@@ -4,10 +4,12 @@
 # Steam shortcut calls this instead of the default minecraftSplitscreen.sh.
 set -euo pipefail
 
-REPO_DIR="$HOME/MinecraftSplitscreenSteamdeck"
+REPO_DIR="${MCSS_REPO_DIR:-$HOME/MinecraftSplitscreenSteamdeck}"
 
-# Ensure repo is up to date
-cd "$REPO_DIR" && git pull -q 2>/dev/null || true
+# No auto-pull: a Steam launch must not mutate the checkout, and an offline
+# Deck would sit on the TCP timeout with nothing on screen (PRINCIPLES #6).
+# Pull + deploy.sh by hand — "git pull is not a deploy" (README §Developing).
+cd "$REPO_DIR" || { echo "minecraftsplitscreen-test.sh: no checkout at $REPO_DIR" >&2; exit 1; }
 
 # Run the prototype in test mode, passing through any extra args (test number)
 exec "$REPO_DIR/minecraftSplitscreen.sh" test "$@"
```

### F14. Fetched helper executed unverified; cleanup only if under `/tmp` — which also deletes a checkout's own helper
`uninstall-minecraft-splitscreen.sh:417-426,438,444`. `[[ "$helper" == /tmp/* ]] && rm -f "$helper"` (a) leaks the download when `mktemp -t` honours `TMPDIR`, and (b) — reproduced while drafting these issues — deletes the **checkout's** `remove-from-steam.py` whenever the checkout itself lives under `/tmp` (a CI scratch clone: `tests/test_uninstall_purge.sh` went 16/22 with `FileNotFoundError` on the helper until this fix was applied; 22/22 after). Compare to the exact temp path instead. Verifying `MCSS_REPO_RAW_URL` against the expected host, or shipping a sha256 for the helper per release, is the fuller fix (same trust model as F3).
```diff
--- a/uninstall-minecraft-splitscreen.sh
+++ b/uninstall-minecraft-splitscreen.sh
@@ -410,12 +410,11 @@
 # Inputs: Globals: DRY_RUN, SCRIPT_DIR, TARGET_DIR (read); removed_count
 # Outputs: side effects — runs the helper; print_* UX to stdout; return 0
 remove_steam_shortcut() {
-    local helper=""
+    local helper="" tmp=""
     if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/remove-from-steam.py" ]]; then
         helper="$SCRIPT_DIR/remove-from-steam.py"
     else
         local raw="${MCSS_REPO_RAW_URL:-https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main}"
-        local tmp
         tmp="$(mktemp -t mcss-remove-from-steam.XXXXXX.py)"
         if command -v curl >/dev/null 2>&1 \
             && curl -fsSL --max-time 20 "$raw/remove-from-steam.py" -o "$tmp" \
@@ -441,7 +440,9 @@
         # Exit 2 = Steam is running; the helper already explained it.
         print_warning "Steam shortcut was NOT removed (see the message above)."
     fi
-    [[ "$helper" == /tmp/* ]] && rm -f "$helper"
+    # Remove exactly the file WE fetched — never a checkout's own helper (a
+    # checkout under /tmp, e.g. a CI scratch dir, matched the old /tmp/* test).
+    [[ -n "$tmp" ]] && rm -f "$tmp"
     return 0
 }
 
```

### F15. `--keep-data` leaves most of "our" launcher tree behind; two targets nothing writes
`uninstall-minecraft-splitscreen.sh:83-93`. `modules/` (runtime_deploy.sh), `bin/evsieve` + stamp (evsieve_management.sh) and `java/` (~300 MB, java_management.sh) are ours and survive; `live.check` and `PolyMC-*.log` have no writer in this repo. `tests/test_uninstall_purge.sh` T3.1/T3.3 (key + worlds survive `--keep-data`) still pass with this applied; add a T3.4 asserting `modules/` and `java/` are gone.
```diff
--- a/uninstall-minecraft-splitscreen.sh
+++ b/uninstall-minecraft-splitscreen.sh
@@ -80,11 +80,15 @@
     "$HOME/.config/minecraft-splitscreen"
 )
 
+# Everything here is OURS (launcher_setup.sh, runtime_deploy.sh,
+# evsieve_management.sh, java_management.sh write it); instances/, accounts.json
+# and PolyMC's own config are what "keep data" keeps.
 KEEP_DATA_TARGETS=(
     "$TARGET_DIR/PolyMC.AppImage"
     "$TARGET_DIR/minecraftSplitscreen.sh"
-    "$TARGET_DIR/live.check"
-    "$TARGET_DIR/PolyMC-*.log"
+    "$TARGET_DIR/modules"
+    "$TARGET_DIR/bin"
+    "$TARGET_DIR/java"
     "$TARGET_DIR/minecraft-splitscreen-icons"
     "$PRISM_DIR/PrismLauncher.AppImage"
     "$PRISM_DIR/minecraftSplitscreen.sh"
```

### F16. `deploy.sh`: non-atomic `cp` into a live tree, hard-coded `--help` range, third env-var name, stamp failure reported as success
`deploy.sh:44,52,186-187,205-212`. A launcher mid-`source` can read a truncated module (STYLE-GUIDE §7.9 asks for tmp + mv). Exercised the patched script against a scratch target: deploy, `--check` fresh, no `*.tmp.*` left behind, `--help` prints the header up to the version-history block.
```diff
--- a/deploy.sh
+++ b/deploy.sh
@@ -41,7 +41,9 @@
 
 SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
 
-TARGET_DIR="${MCSS_TARGET_DIR:-$HOME/.local/share/PolyMC}"
+# MCSS_TARGET_DIR is this tool's name; TARGET_DIR is the installer's and the
+# uninstaller's — honour both so one env var relocates every tool.
+TARGET_DIR="${MCSS_TARGET_DIR:-${TARGET_DIR:-$HOME/.local/share/PolyMC}}"
 CHECK_ONLY=false
 
 while [[ $# -gt 0 ]]; do
@@ -49,7 +51,10 @@
         --check)  CHECK_ONLY=true; shift ;;
         --target) TARGET_DIR="${2:?--target requires a directory}"; shift 2 ;;
         -h|--help)
-            sed -n '2,31p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
+            # Print the header up to (not including) the version-history block,
+            # whatever its length — a hard-coded line range drifts.
+            sed -n '2,/^# Version history/{/^# Version history/!p}' "${BASH_SOURCE[0]:-$0}" \
+                | sed 's/^# \{0,1\}//'
             exit 0 ;;
         *) echo "deploy.sh: unknown argument: $1 (try --help)" >&2; exit 2 ;;
     esac
@@ -183,8 +188,9 @@
     fi
     if files_differ "$src" "$dst" "$normalize"; then
         status="updated"; [[ -f "$dst" ]] || status="NEW"
-        cp "$src" "$dst"
-        chmod +x "$dst"
+        # tmp + mv (STYLE-GUIDE §7.9): the Deck may be sourcing this very file
+        # while we deploy; an in-place cp can hand it a truncated module.
+        cp "$src" "$dst.tmp.$$" && chmod +x "$dst.tmp.$$" && mv -f "$dst.tmp.$$" "$dst"
         echo "  → $label ($status)"
         changed=$((changed + 1))
     else
@@ -202,15 +208,22 @@
 if [[ "$launcher_differs" == true || $changed -gt 0 || ! -f "$LAUNCHER_DST" ]]; then
     status="updated"; [[ -f "$LAUNCHER_DST" ]] || status="NEW"
     [[ "$launcher_differs" == true || ! -f "$LAUNCHER_DST" ]] || status="re-stamped"
-    cp "$LAUNCHER_SRC" "$LAUNCHER_DST"
-    chmod +x "$LAUNCHER_DST"
+    # Stamp a temp copy and mv it into place, so the live launcher is never
+    # half-copied or copied-but-unstamped.
+    _tmp="$LAUNCHER_DST.tmp.$$"
+    cp "$LAUNCHER_SRC" "$_tmp"
+    chmod +x "$_tmp"
     changed=$((changed + 1))
     # #89: same format + resolution as the installer, via modules/version_stamp.sh.
     # mark_dirty is ours alone — a dev checkout is routinely uncommitted.
     IFS=$'\t' read -r _ver _commit _date \
         < <(mcss_stamp_resolve "$SCRIPT_DIR" mark_dirty)
-    mcss_stamp_apply "$LAUNCHER_DST" "$_ver" "$_commit" "$_date" || true
-    echo "  → minecraftSplitscreen.sh ($status; stamped version=${_ver} commit=${_commit})"
+    if mcss_stamp_apply "$_tmp" "$_ver" "$_commit" "$_date"; then
+        echo "  → minecraftSplitscreen.sh ($status; stamped version=${_ver} commit=${_commit})"
+    else
+        echo "  → minecraftSplitscreen.sh ($status; STAMP FAILED — placeholders left in place)" >&2
+    fi
+    mv -f "$_tmp" "$LAUNCHER_DST"
 else
     unchanged=$((unchanged + 1))
 fi
```

### F17. CI/release hardening: shellcheck scope, no `timeout-minutes`, no `permissions:`, unpinned actions, every PR runs twice
`ci.yml:33-56`, `release.yml:47,140,150`. The `-S error` gate omits the uninstaller (`rm -rf`), `deploy.sh`, the Steam test wrapper, the root-run `system/` hooks and `tests/` — verified clean over the widened set today, so it costs nothing to gate. Pin `dtolnay/rust-toolchain`, `softprops/action-gh-release`, `actions/checkout|upload-artifact|download-artifact` to commit SHAs (resolve them from the tags at PR time; the evsieve binary users trust is produced by whatever those tags resolve to). The `unit-tests` job body is F2's; this diff adds only the workflow-level hygiene on top of the pristine file.
```diff
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -35,26 +35,45 @@
     branches: ['**']
   pull_request:
 
+# The default token can write; nothing here needs more than a checkout.
+permissions:
+  contents: read
+
+# A PR from a branch in this repo triggers both `push` and `pull_request`;
+# cancel the older run of the same ref instead of running everything twice.
+concurrency:
+  group: ci-${{ github.ref }}
+  cancel-in-progress: true
+
 jobs:
   shellcheck:
     runs-on: ubuntu-latest
+    timeout-minutes: 10
     steps:
       - uses: actions/checkout@v4
 
       - name: Install shellcheck
         run: sudo apt-get update -qq && sudo apt-get install -y shellcheck
 
+      # Every bash entry point the project ships or runs — not only the
+      # launcher + installer: the uninstaller (rm -rf), deploy.sh, the Steam
+      # test wrapper, the system/ hooks that run as root, and tests/.
       - name: shellcheck (error severity — gates the build)
         run: |
-          shellcheck -S error modules/*.sh minecraftSplitscreen.sh install-minecraft-splitscreen.sh
+          shellcheck -S error modules/*.sh minecraftSplitscreen.sh install-minecraft-splitscreen.sh \
+            uninstall-minecraft-splitscreen.sh deploy.sh minecraftsplitscreen-test.sh \
+            system/deck-display-fixes/*.sh tests/*.sh tests/lib/*.sh tests/hardware/*.sh tests/hardware/lib/*.sh
 
       - name: shellcheck (warning severity — informational only)
         if: always()
         run: |
-          shellcheck -S warning modules/*.sh minecraftSplitscreen.sh install-minecraft-splitscreen.sh || true
+          shellcheck -S warning modules/*.sh minecraftSplitscreen.sh install-minecraft-splitscreen.sh \
+            uninstall-minecraft-splitscreen.sh deploy.sh minecraftsplitscreen-test.sh \
+            system/deck-display-fixes/*.sh tests/*.sh tests/lib/*.sh tests/hardware/*.sh tests/hardware/lib/*.sh || true
 
   unit-tests:
     runs-on: ubuntu-latest
+    timeout-minutes: 30
     steps:
       - uses: actions/checkout@v4
 
--- a/.github/workflows/release.yml
+++ b/.github/workflows/release.yml
@@ -31,9 +31,15 @@
                       # (see the `if: github.event_name == 'push'` guards
                       # below); never creates/modifies a real release.
 
+# Creating the release and uploading assets is the ONLY write this workflow
+# needs; say so instead of inheriting the repo default.
+permissions:
+  contents: write
+
 jobs:
   build-evsieve:
     runs-on: ubuntu-22.04
+    timeout-minutes: 30
     outputs:
       built: ${{ steps.build.outcome == 'success' }}
     steps:
@@ -111,6 +117,7 @@
     needs: build-evsieve
     if: always()
     runs-on: ubuntu-latest
+    timeout-minutes: 15
     steps:
       - name: Checkout repository
         uses: actions/checkout@v4
```

### F18 (= C25). Built-in mod defaults duplicate `mods.conf`, and the README install path guarantees the duplicate is used
`install-minecraft-splitscreen.sh:378-398`, `mods.conf`, `README.md:60-63`. README users `wget` only the entry script, so `mods.conf` is always absent for them and the 7-mod parallel arrays (a second encoding, PRINCIPLES #9, with `MOD_DEPS_BY_NAME` dropped) are what installs; an edit to `mods.conf` alone changes nothing for users. Fetch it from `MCSS_REPO_RAW_URL` like `accounts.json`, and demote the arrays to a loudly-labelled offline last resort (a follow-up can delete them and hard-fail instead; `tests/test_installer.sh` T7.4 greps the installer for `Controlify`, so keep that string or update the test).
```diff
--- a/install-minecraft-splitscreen.sh
+++ b/install-minecraft-splitscreen.sh
@@ -372,13 +372,27 @@
 declare -A MOD_DEPS_BY_NAME=()
 
 # load_mods_config: Populate MODS, REQUIRED_SPLITSCREEN_MODS, and
-# REQUIRED_SPLITSCREEN_IDS from mods.conf (next to this script).
-# Falls back to built-in defaults if the file is missing.
+# REQUIRED_SPLITSCREEN_IDS from mods.conf (next to this script, or fetched
+# from MCSS_REPO_RAW_URL when there is no checkout — the same pattern as
+# accounts.json / add-to-steam.py). The built-in defaults below are a LAST
+# RESORT for an offline run, not a second encoding to keep in sync
+# (PRINCIPLES #9): mods.conf is the one home of the mod list.
 load_mods_config() {
     local conf="${SCRIPT_DIR}/mods.conf"
 
     if [[ ! -f "$conf" ]]; then
-        echo "[mods] mods.conf not found at ${conf} — using built-in defaults" >&2
+        conf="$MODULES_DIR/mods.conf"
+        echo "[mods] no local mods.conf — fetching ${MCSS_REPO_RAW_URL}/mods.conf" >&2
+        if command -v curl >/dev/null 2>&1; then
+            curl -fsSL --connect-timeout 10 --max-time 60 "${MCSS_REPO_RAW_URL}/mods.conf" -o "$conf" 2>/dev/null || rm -f "$conf"
+        elif command -v wget >/dev/null 2>&1; then
+            wget -q --timeout=10 --tries=2 "${MCSS_REPO_RAW_URL}/mods.conf" -O "$conf" 2>/dev/null || rm -f "$conf"
+        fi
+    fi
+
+    if [[ ! -s "$conf" ]]; then
+        echo "[mods] mods.conf unavailable (no checkout, fetch failed) — using built-in LAST-RESORT defaults" >&2
+        echo "[mods] WARNING: these may lag mods.conf; re-run online or from a checkout to get the current list" >&2
         # NOTE: the "Splitscreen Support" mod (yJgqfSDR) is NO LONGER installed — window
         # tiling is done by KWin, not the mod (2026-06-23).
         # Standard performance set as of 2026-07-17 — see mods.conf for rationale.
```

### F19. curl|bash: `SCRIPT_DIR` = CWD picks up a stray `modules/`; download loop leaks globals
`install-minecraft-splitscreen.sh:101,263-268,199-200,214-215`. `cd ~/projects/foo && curl … | bash` where `foo/modules/` exists copies it in and dies with "manifest missing" (or sources same-named `.sh` files). Treat the directory as our checkout only when both the manifest and the launcher are present; `local` the four temporaries (STYLE-GUIDE §7.4).
```diff
--- a/install-minecraft-splitscreen.sh
+++ b/install-minecraft-splitscreen.sh
@@ -183,6 +183,7 @@
     # The temporary directory is already created by mktemp
     local downloaded_count=0
     local failed_count=0
+    local curl_output curl_exit_code wget_output wget_exit_code
     
     # Download each required module
     for module in "${MODULE_FILES[@]}"; do
@@ -260,7 +261,13 @@
 # Acquire the runtime-module MANIFEST first — the download and presence steps
 # below derive from it. A local checkout's cp brings it along; a curl|bash
 # install fetches just the manifest, then downloads everything it names.
-if [[ -d "$SCRIPT_DIR/modules" ]]; then
+# "Is a checkout" means OUR checkout: under curl|bash SCRIPT_DIR is the
+# caller's CWD, and any project's stray modules/ there must not be copied in.
+_LOCAL_CHECKOUT=false
+if [[ -f "$SCRIPT_DIR/modules/$RUNTIME_MANIFEST_NAME" && -f "$SCRIPT_DIR/minecraftSplitscreen.sh" ]]; then
+    _LOCAL_CHECKOUT=true
+fi
+if [[ "$_LOCAL_CHECKOUT" == true ]]; then
     if [[ "$DEBUG_MODE" == true ]]; then
         echo "📁 Found local modules directory, copying to temporary location..."
     fi
@@ -292,7 +299,7 @@
 
 # In download mode the modules themselves are still missing — fetch them now
 # that the manifest says what to fetch.
-if [[ ! -d "$SCRIPT_DIR/modules" ]]; then
+if [[ "$_LOCAL_CHECKOUT" != true ]]; then
     download_modules
 fi
 
```

### F20. README / system README claims that no longer match the code
`README.md:68` ("builds … in a container" — since #126 the installer fetches the prebuilt asset first), `system/deck-display-fixes/README.md:12` (`predock-probe.sh` is not in the repo and `install.sh` never installs it), `:13` (hotplug row contradicts the code — F7's diff rewrites that row).
```diff
--- a/README.md
+++ b/README.md
@@ -65,7 +65,7 @@
 
 The installer downloads Minecraft and the splitscreen pieces and adds a **"Minecraft Splitscreen"** shortcut to your Steam library. It asks a couple of simple yes/no questions as it goes, and stops with a clear message if your device is missing something it needs.
 
-Part way through it builds a small input helper (`evsieve` — the piece that keeps your controller's slot alive across a disconnect) in a container, which takes a couple of minutes and prints progress while it works.
+Part way through it downloads a small prebuilt input helper (`evsieve` — the piece that keeps your controller's slot alive across a disconnect) from the release and verifies it. Only if that download is unavailable does it build the helper itself in a container, which takes a couple of minutes and prints progress while it works.
 
 ---
 
--- a/system/deck-display-fixes/README.md
+++ b/system/deck-display-fixes/README.md
@@ -9,7 +9,6 @@
 
 | File | Installed to | Role |
 |------|--------------|------|
-| `predock-probe.sh` *(pre-existing, Deck-only)* | `~/.local/bin/` | Waits for EDID before gamescope takes DRM master (boot-with-dock MST race) |
 | `dock-display-hotplug.sh` | `~/.local/bin/` | udev-triggered; restarts gamescope only if MST probe failed (EDID missing). Sanitizes env first. |
 | `resume-display-restore.sh` | `~/.local/bin/` | Oneshot worker: sanitize env → nudge gamescope if docked |
 | `resume-display-restore.service` | `~/.config/systemd/user/` | Oneshot unit for the worker |
```

### F21. `system/…/install.sh` assumes a live user session and has no uninstall
`install.sh:12,18,21`. Over SSH without `DBUS_SESSION_BUS_ADDRESS`, `systemctl --user daemon-reload` aborts under `set -e` after the user files were copied and before the root hook — a half install. No inverse exists for the `/etc/systemd/system-sleep` hook, so `uninstall-minecraft-splitscreen.sh --purge` ("leave no trace") leaves a root-owned hook that restarts gamescope on resume (F8). Export the runtime vars the way the worker does; add `--remove`; announce the `sudo` step (PRINCIPLES #6). After F7 lands, `--remove` should also `sudo rm` the udev rule and `udevadm control --reload`.
```diff
--- a/system/deck-display-fixes/install.sh
+++ b/system/deck-display-fixes/install.sh
@@ -6,6 +6,25 @@
 HERE="$(cd "$(dirname "$0")" && pwd)"
 USER_BIN="$HOME/.local/bin"
 USER_SYSD="$HOME/.config/systemd/user"
+
+# Over a plain SSH login there is no session bus in the environment and
+# `systemctl --user` fails ("Failed to connect to bus") — after the user
+# files were copied but before the root hook, a half install. Same guard the
+# worker itself carries.
+export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
+export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
+
+if [[ "${1:-}" == "--remove" ]]; then
+    systemctl --user disable --now resume-display-restore.service 2>/dev/null || true
+    rm -f "$USER_BIN/resume-display-restore.sh" "$USER_BIN/dock-display-hotplug.sh" \
+          "$USER_SYSD/resume-display-restore.service"
+    systemctl --user daemon-reload
+    echo "Removing the root-side resume hook (sudo)..."
+    sudo rm -f /etc/systemd/system-sleep/deck-display-resume.sh
+    echo "Removed."
+    exit 0
+fi
+
 mkdir -p "$USER_BIN" "$USER_SYSD"
 
 # Stop+disable the OLD persistent journalctl-tail service before overwriting it.
@@ -18,6 +37,7 @@
 systemctl --user daemon-reload
 
 # Root: the system-sleep hook is the robust resume trigger.
+echo "Installing the root-side resume hook (sudo may prompt)..."
 sudo install -m 0755 "$HERE/deck-display-resume.sh" /etc/systemd/system-sleep/deck-display-resume.sh
 
 echo "Installed."
```

### F22. `.gitignore` — no issues
`.gitignore:3-5,13`. `token.enc`, `*.log`, `*.tmp`, `ISSUES.md` ignored; nothing sensitive tracked. `*.log` is broad — add `!tests/**/*.log` if a fixture ever needs it. No change required; listed so the review's coverage is recorded.

## Hardware verification
F9, F10, F13, F14, F15, F16, F17, F18, F19, F20, F22 are installer/dev-tool/CI/doc changes: CI + the existing unit suites (`tests/test_installer.sh`, `tests/test_uninstall_purge.sh`) cover them, plus one real install from a curl|bash-style download on the Deck (Desktop Mode: `wget` the entry script into an empty directory and run it; F18's `[mods] no local mods.conf — fetching …` line must appear and the mod list must match `mods.conf`) followed by `tests/hardware/stage0b_install.sh`. F11, F12 and F21 change the root-side `system/` hooks: on a docked Deck in Game Mode, reinstall with `./install.sh`, suspend/resume once and confirm `journalctl --user -t resume-display-restore` shows the worker ran (F12 moves the log there), then `./install.sh --remove` and confirm `/etc/systemd/system-sleep/deck-display-resume.sh` and the user unit are gone — this is the same session-survival check as F8, which should be validated together.

## References
Review F9–F22 and C25 (`docs/reviews/2026-09-28/F-install-ops.md`, `C-installer-mods.md`, CODE-REVIEW §5.6); PRINCIPLES #6 (F10, F13, F21), #7 (F14, F15), #9 (F11, F16, F18). Related issues: F1/F6 (uninstaller blast radius), F2 (CI gate — F17 layers on it), F3 (release pinning — F9 validates the same variable), F7/F8 (`system/` behaviour — F11/F12/F21 are their hygiene), #196 (evsieve prebuilt path that F20's README wording now describes).
