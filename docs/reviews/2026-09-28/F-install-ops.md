# F — Install / uninstall / deploy / system / CI review

Scope (read fully): `install-minecraft-splitscreen.sh`, `uninstall-minecraft-splitscreen.sh`,
`deploy.sh`, `minecraftsplitscreen-test.sh`, `system/deck-display-fixes/*`,
`.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.gitignore`, `README.md`
(claims only). Callees opened for contracts: `modules/runtime_deploy.sh`,
`modules/utilities.sh` (`fetch_url`, `mcss_prompt`), `modules/evsieve_management.sh`,
`modules/version_stamp.sh`, `modules/runtime_context.sh` (launcher-root probe),
`modules/system_integration.sh`, `modules/main_workflow.sh`, `remove-from-steam.py`,
`tests/test_*.sh` (summary-line format + exit codes; all 19 CI-gated suites were executed
locally to get real totals).

Known-issue docs grepped (BUG-AUDIT-2026-06-24-followup, AUDIT-2026-07-21,
CODE-REVIEW-2026-07-21-CLOSED, IMPROVEMENTS-ANALYSIS-2026-08-15, TODO): none of the
findings below are recorded there except where tagged.

---

### F1. Full uninstall `rm -rf`s the user's PrismLauncher root, which this project never installs
- **Severity:** High
- **Category:** security
- **File:** `uninstall-minecraft-splitscreen.sh:63`, `uninstall-minecraft-splitscreen.sh:66-74`, `uninstall-minecraft-splitscreen.sh:295-297`
- **Status:** CONFIRMED
- **What:** `PRISM_DIR="${PRISM_DIR:-$HOME/.local/share/PrismLauncher}"` is placed whole in
  `FULL_TARGETS=( "$TARGET_DIR" "$PRISM_DIR" ... )` and removed with `rm -rf "$path"`
  (line 280). The installer only ever writes under `TARGET_DIR=$HOME/.local/share/PolyMC`
  (`launcher_setup.sh:94` downloads `PolyMC.AppImage` there; `java_management.sh:176`,
  `runtime_deploy.sh:61/132`, `system_integration.sh:411`, `evsieve_management.sh` →
  `$TARGET_DIR/bin`). `PrismLauncher` appears in the codebase only as a *probe fallback*
  (`runtime_context.sh:271`, `utilities.sh:66`) — nothing creates it. Prism is the most
  popular third-party MC launcher on the Deck, so this directory commonly holds instances
  and worlds that belong to the user, not to us. This is the "remove only what you
  created" rule (PRINCIPLES #7 blast radius, which the same file cites for the podman
  store at lines 305-311) applied inconsistently.
- **Failure scenario:** User has their own Prism install with worlds, plus this project.
  `uninstall-minecraft-splitscreen.sh --yes` (or `--purge --yes`, or answers `n`/`y` to
  the prompts) → `~/.local/share/PrismLauncher` and every world in it is deleted. With
  `--yes` there is no confirmation at all.
- **Fix:** Remove `$PRISM_DIR` from `FULL_TARGETS`. If a Prism-hosted install must be
  supported, delete only *our* artefacts under it (`minecraftSplitscreen.sh`, `modules/`,
  `bin/evsieve`, `instances/${MCSS_INSTANCE_PREFIX}*`), and only when a marker such as
  `$PRISM_DIR/minecraftSplitscreen.sh` exists. Same reasoning applies (weaker) to
  `"$HOME/.local/jdk"` at line 73 — a generic path a user may have populated themselves.

### F2. CI baseline gate lets regressions through: test totals exceed the baseline and suite exit codes are discarded
- **Severity:** High
- **Category:** test-quality
- **File:** `.github/workflows/ci.yml:84`, `.github/workflows/ci.yml:94`, `.github/workflows/ci.yml:102`, `.github/workflows/ci.yml:12-18`
- **Status:** CONFIRMED
- **What:** The gate is `if (( passed < BASELINE[$suite] ))` with `out=$(bash "$suite" 2>&1) || true`.
  Only a lower bound on *passed* is checked; the *total* is never compared and the suite's
  exit status is thrown away. Running every gated suite locally:
  `tests/test_uhid_pad.sh` prints `23/23 tests passed` but its baseline is
  `[tests/test_uhid_pad.sh]=18` — five tests can fail with CI green. Every other suite
  is exactly at baseline except `test_window_manager.sh` (7/9, the two documented
  known-fails), so today the whole gate rests on nobody adding tests without also editing
  the YAML. The design comment at lines 12-14 ("none of these scripts exit non-zero on a
  failed sub-test") is stale: 17 of the 19 gated suites now `exit 1` on failure
  (e.g. `tests/test_controller_monitor.sh:1128`, `tests/test_uhid_pad.sh:197`), so the
  cheaper, drift-proof gate (exit code) is available and ignored. This also violates
  PRINCIPLES #4 in spirit — a mutation that breaks up to 5 uhid_pad behaviours stays green.
- **Failure scenario:** A PR breaks 3 of the 23 `test_uhid_pad` cases → suite prints
  `20/23 tests passed` and exits 1 → CI prints `OK: 20 >= 18` → merge.
- **Fix:** Gate on the suite exit code for every suite, and keep an explicit
  known-fail allowlist only for `test_window_manager.sh` (with its baseline *and* total):
  ```bash
  if ! bash "$suite" >"$log" 2>&1 && [[ -z "${KNOWN_FAIL[$suite]:-}" ]]; then fail=1; fi
  ```
  Or at minimum also parse the total and fail when `total > baseline + allowed_known_fails`.
  Bump `test_uhid_pad.sh` to 23 now.

### F3. Release-asset installer (and every curl|bash run) fetches modules from unpinned `main`, with no integrity check
- **Severity:** Medium
- **Category:** security
- **File:** `install-minecraft-splitscreen.sh:109`, `install-minecraft-splitscreen.sh:115`, `install-minecraft-splitscreen.sh:199`, `.github/workflows/release.yml:138-146`
- **Status:** CONFIRMED
- **What:** `export REPO_REF="${REPO_REF:-main}"` and
  `MCSS_REPO_RAW_URL="https://raw.githubusercontent.com/aradanmn/.../${REPO_REF}"`.
  `release.yml` uploads `install-minecraft-splitscreen.sh` byte-for-byte
  (`files: install-minecraft-splitscreen.sh`), so the "v1.2.4" release asset still pulls
  `modules/*.sh`, `minecraftSplitscreen.sh`, `accounts.json`, `add-to-steam.py` and the
  evsieve patch from whatever `main` is at run time. The entry script and its modules
  can therefore be from different commits (module API drift = mysterious install failure),
  a release is not reproducible, and a force-push/compromise of `main` is executed on every
  install (`chmod +x` + `source`, line 202/312-327). Transport is HTTPS only; there is no
  checksum or signature over the module set (contrast the care taken for evsieve in
  `evsieve_management.sh:60-110`).
- **Failure scenario:** Tag `v1.2.5` cut; two days later a module on `main` renames a
  function the tagged entry script calls → users downloading the v1.2.5 asset get an
  installer that dies mid-run. Or: someone with push access to `main` (or a hijacked
  GitHub session) changes `utilities.sh` → executed by every installer worldwide.
- **Fix:** In `release.yml`, bake the tag into the uploaded asset before upload:
  `sed -i 's/^export REPO_REF="${REPO_REF:-main}"/export REPO_REF="${REPO_REF:-'"$GITHUB_REF_NAME"'}"/'`
  (or resolve to the commit SHA). Longer term ship a `modules.sha256` alongside and verify
  in `download_modules` (same shape as `_evsieve_try_prebuilt`).

### F4. Installer's `trap cleanup EXIT INT TERM` swallows Ctrl-C: the script keeps running after deleting its own module dir
- **Severity:** Medium
- **Category:** bug
- **File:** `install-minecraft-splitscreen.sh:82-90`, `modules/utilities.sh:329-332`
- **Status:** CONFIRMED (reproduced with a minimal script: after SIGINT the trap ran, `rm -rf` removed the dir, and execution continued to the next statement)
- **What:** The INT/TERM handler is `cleanup` alone — it never re-raises or `exit`s. Bash
  semantics: the foreground child gets the SIGINT, the trap runs, then the script resumes
  at the next command. Aborting therefore depends on `set -e` seeing a non-zero status,
  which is defeated everywhere the installer deliberately shields commands: the
  `set +e` window in `download_modules` (181-239), every `|| true` / `if cmd` guard, and
  every prompt — `mcss_prompt` does `if ! read -r -p "$prompt" _mcss_prompt_out; then
  ... _mcss_prompt_out="$eof_default"` so a Ctrl-C *at a prompt* is indistinguishable from
  EOF and the installer proceeds with the default answer. Meanwhile `MODULES_DIR` has
  already been `rm -rf`'d, so `install_runtime_modules()` tier 1 (`runtime_deploy.sh:172`)
  silently misses and tier 3 re-downloads from `main` instead of deploying the modules the
  user ran (from a checkout, the ones they intended).
- **Failure scenario:** `./install-minecraft-splitscreen.sh` from a feature-branch
  checkout; user hits Ctrl-C at the "Add to Steam?" prompt to abort → prompt takes the
  EOF default, install continues, and the deployed `modules/` comes from GitHub `main`,
  not the checkout — exactly the drift `deploy.sh` exists to catch.
- **Fix:**
  ```bash
  trap cleanup EXIT
  trap 'cleanup; trap - EXIT; exit 130' INT
  trap 'cleanup; trap - EXIT; exit 143' TERM
  ```

### F5. Uninstaller is documented as curl|bash-able but its prompts read the script stream, so a piped run silently does nothing
- **Severity:** Medium
- **Category:** bug
- **File:** `uninstall-minecraft-splitscreen.sh:5`, `uninstall-minecraft-splitscreen.sh:183`, `uninstall-minecraft-splitscreen.sh:235`
- **Status:** CONFIRMED (`cat uninstall-minecraft-splitscreen.sh | HOME=<fake> bash` prints the target list then `ℹ️  No changes made.`, exit 0, nothing removed)
- **What:** Header: "Standalone, curl|bash-able uninstaller". Both prompts are
  `read -r -p "..." keep_choice` / `confirm` from stdin. When the script arrives on stdin,
  `read` consumes the next unparsed line of the *script itself* (a blank line after each
  `if…fi` block), so `keep_choice=""` → keep-data, and `confirm=""` → "No changes made".
  The only working piped form is `bash -s -- --yes --purge|--keep-data`, which is not what
  the header says. The installer has the same shape (`mcss_prompt` reads stdin) but there
  the EOF path is explicitly designed and README tells users to download-then-run.
- **Failure scenario:** `curl -fsSL .../uninstall-minecraft-splitscreen.sh | bash` →
  prints "No changes made." and exits 0; user believes the uninstall ran.
- **Fix:** Read prompts from the terminal when one exists:
  `read -r -p "..." confirm </dev/tty` (fallback to stdin/EOF-default when `/dev/tty` is
  unavailable), or drop the "curl|bash-able" claim and refuse when `! -t 0` and no mode
  flag was given.

### F6. `rm -rf` on env-supplied `TARGET_DIR`/`PRISM_DIR` with no sanity validation, and `--yes` removes the only guard
- **Severity:** Medium
- **Category:** security
- **File:** `uninstall-minecraft-splitscreen.sh:62-63`, `uninstall-minecraft-splitscreen.sh:280`
- **Status:** CONFIRMED
- **What:** `TARGET_DIR="${TARGET_DIR:-$HOME/.local/share/PolyMC}"` is accepted verbatim and
  fed to `rm -rf "$path"`. Nothing checks it is absolute, is not `/`, is not `$HOME`, or
  looks like one of our installs (e.g. contains `minecraftSplitscreen.sh` or `instances/`).
  `TARGET_DIR` is a generic name that other tooling exports (it is also the *installer's*
  readonly global name, so a shell that previously sourced the installer for testing has
  it set). The list is printed before the confirmation, but `--yes` skips that.
- **Failure scenario:** `TARGET_DIR=$HOME ./uninstall-minecraft-splitscreen.sh --yes`
  (typo'd relocation, or a stale export from a test harness) → home directory removed.
- **Fix:** Before building the target arrays:
  ```bash
  for d in "$TARGET_DIR" "$PRISM_DIR"; do
      [[ "$d" == /* && "$d" != "/" && "$d" != "$HOME" && "$d" != "$HOME/" ]] || { echo "refusing to remove $d" >&2; exit 1; }
  done
  ```
  and in full mode require an install marker (`-e "$d/minecraftSplitscreen.sh" || -d "$d/instances"`) or skip with a warning.

### F7. `dock-display-hotplug.sh` has no udev rule, needs root, and its README description contradicts the code
- **Severity:** Medium
- **Category:** dead-code
- **File:** `system/deck-display-fixes/dock-display-hotplug.sh:2`, `system/deck-display-fixes/dock-display-hotplug.sh:55-59`, `system/deck-display-fixes/install.sh:15`, `system/deck-display-fixes/README.md:13`
- **Status:** CONFIRMED (no `*.rules` file exists anywhere in the repo or its history — `git log --all --diff-filter=A -- '*.rules'` is empty; the only system files ever added are the five in this directory)
- **What:** The script says "Fired by udev on any DRM hotplug event" and ends with
  `su -s /bin/bash deck -c "... systemctl --user restart gamescope-session.target"`, which
  only works as root. `install.sh` merely copies it to `~/.local/bin` (`install -m 0755 ...
  "$USER_BIN/dock-display-hotplug.sh"`) and installs no udev rule, so after `./install.sh`
  nothing ever runs it; if a user runs it by hand, `su` prompts for the `deck` password
  (with `2>/dev/null` the prompt is hidden — an unbounded silent wait, PRINCIPLES #6).
  README line 13 says it "restarts gamescope only if MST probe failed (EDID missing)";
  the code header (line 4) says "Restarts gamescope whenever a DP connector is connected
  with valid EDID" and the loop does exactly that (`edid_size -gt 0 → stable=1 → break 2`
  → restart). `stable` is then never read (shellcheck SC2034). If a rule were added,
  a 45 s polling loop (`MAX_WAIT=45`, `sleep 1`) inside a udev `RUN+=` handler is against
  udev's "no long-running programs" rule and would be killed at the event timeout on
  some systemd versions (PLAUSIBLE for that sub-point).
- **Failure scenario:** Maintainer follows README's `./install.sh`, believes hotplug
  recovery is in place; a dock re-plug that loses EDID is never handled.
- **Fix:** Either ship + install the rule (e.g.
  `ACTION=="change", SUBSYSTEM=="drm", ENV{HOTPLUG}=="1", RUN+="/usr/bin/systemd-run --no-block /home/deck/.local/bin/dock-display-hotplug.sh"`)
  via `sudo install` in `install.sh`, or delete the script and the README row. Fix the
  README sentence to match the actual restart condition.

### F8. `resume-display-restore.sh` restarts the whole gamescope session on every docked resume — a running game (including a splitscreen session) is killed unconditionally
- **Severity:** Medium
- **Category:** principle-violation
- **File:** `system/deck-display-fixes/resume-display-restore.sh:52-60`, `system/deck-display-fixes/deck-display-resume.sh:14-20`
- **Status:** CONFIRMED
- **What:** The system-sleep hook fires the oneshot on *every* `post` resume; the worker
  does `if [ "$external" -eq 1 ]; then ... restart_gamescope` where `external` is just
  "any `card0-DP-*` status is `connected`". There is no check that the external output is
  actually *broken* (no gamescope log probe, no `is-active` failure, no missing-EDID
  test). `systemctl --user restart gamescope-session.target` tears down Steam and every
  game under it. PRINCIPLES #5: "A false positive must not kill a running player's
  session" — here there isn't even a detector, restart is the default.
- **Failure scenario:** Four players mid-game, Deck docked; the Deck auto-suspends on
  idle-lid/power event or the user briefly suspends → on resume the session restarts →
  all four Minecraft instances die.
- **Fix:** Only restart when a failure is observed: e.g. after the `sleep 8`, check that
  gamescope has the DP output enabled (`/sys/class/drm/card0-DP-*/enabled == enabled`
  and `dpms == On`) or that `gamescope-session.target` is *not* active; otherwise
  `log "docked, output healthy -> no action"`. Keep the env-sanitize step unconditional
  (that part is harmless).

### F9. `REPO_REF` is interpolated into the fetch URL unvalidated; curl squashes `..` so it can point at any GitHub repo
- **Severity:** Low
- **Category:** security
- **File:** `install-minecraft-splitscreen.sh:109`, `install-minecraft-splitscreen.sh:115`
- **Status:** CONFIRMED (`curl -v https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/../../foo/bar/main/x` sends `GET /foo/bar/main/x`)
- **What:** `REPO_REF="${REPO_REF:-main}"` then
  `MCSS_REPO_RAW_URL=".../MinecraftSplitscreenSteamdeck/${REPO_REF}"`. A ref such as
  `../../someone/otherrepo/main` makes every module/launcher/patch fetch come from a
  different repository, with the messages still saying "aradanmn/...". `REPO_REF` is
  only an environment variable, so exploitation needs control of the operator's env
  (low), but it also breaks silently on refs with `/` that legitimately contain
  branch names like `feat/x` (those work) vs. typos.
- **Failure scenario:** A shared shell profile / CI job exports a crafted `REPO_REF`;
  the installer sources arbitrary bash from another repo and prints the official URL.
- **Fix:** `[[ "$REPO_REF" =~ ^[A-Za-z0-9._/-]+$ && "$REPO_REF" != *..* ]] || { echo "bad REPO_REF"; exit 1; }`.

### F10. Bootstrap downloads have no timeout — unbounded waits in the operator path
- **Severity:** Low
- **Category:** principle-violation
- **File:** `install-minecraft-splitscreen.sh:199`, `install-minecraft-splitscreen.sh:214`, `install-minecraft-splitscreen.sh:275-277`
- **Status:** CONFIRMED
- **What:** `curl -fsSL "$module_url" -o "$module_path"` and `wget -q ...` carry no
  `--max-time`/`--connect-timeout`/`--timeout`, unlike `fetch_url` (`utilities.sh:93`,
  default 15 s) which exists precisely because "pre-D14 sites used un-timeouted curl that
  would hang rather than fail". The bootstrap can't use `fetch_url` (not yet sourced), but
  it can carry the same options. PRINCIPLES #6.
- **Failure scenario:** Stalled TCP connection to raw.githubusercontent.com → installer
  sits forever with no spinner/countdown (`-s` silences progress too).
- **Fix:** Add `--connect-timeout 10 --max-time 60` to both curl calls and
  `--timeout=10 --tries=2` to wget; keep the literal in one named constant
  (`BOOTSTRAP_FETCH_TIMEOUT_S`).

### F11. Hard-coded `deck` user, UID 1000 and `/home/deck` throughout `system/`; the `.service` is copied verbatim into `$HOME`
- **Severity:** Low
- **Category:** hardcoded
- **File:** `system/deck-display-fixes/resume-display-restore.service:12`, `system/deck-display-fixes/deck-display-resume.sh:16-18`, `system/deck-display-fixes/dock-display-hotplug.sh:55-57`, `system/deck-display-fixes/resume-display-restore.sh:16-17`, `system/deck-display-fixes/install.sh:16`
- **Status:** CONFIRMED
- **What:** `ExecStart=/home/deck/.local/bin/resume-display-restore.sh` while `install.sh`
  installs the worker to `"$HOME/.local/bin"` and the unit to `"$HOME/.config/systemd/user"`
  — on any account other than `deck` the unit points at a non-existent file and
  `systemctl --user start` fails silently (`--no-block`, output discarded). The user name
  and UID are repeated in three files (drift risk, PRINCIPLES #9). README does say
  Deck-only, but the installer accepts any `$HOME`.
- **Failure scenario:** Bazzite/CachyOS user (README calls these "experimental") runs
  `install.sh`; the resume worker never starts, no error anywhere.
- **Fix:** `ExecStart=%h/.local/bin/resume-display-restore.sh` (systemd specifier), and in
  the root-side hooks derive the user once: `DECK_USER=${DECK_USER:-deck}; DECK_UID=$(id -u "$DECK_USER")`.
  Have `install.sh` refuse when `$USER != deck` unless overridden.

### F12. Root-run hook writes a predictable file in world-writable `/tmp` (symlink/tamper); worker log likewise
- **Severity:** Low
- **Category:** security
- **File:** `system/deck-display-fixes/dock-display-hotplug.sh:17`, `system/deck-display-fixes/dock-display-hotplug.sh:21-23`, `system/deck-display-fixes/dock-display-hotplug.sh:50`, `system/deck-display-fixes/resume-display-restore.sh:19`
- **Status:** CONFIRMED (code); exploitability on a single-user Deck is low
- **What:** `STAMP=/tmp/gamescope-hotplug-restart-stamp`; the script is designed to run
  as root (see F7) and does `date +%s > "$STAMP"` — following a symlink planted by any
  local user. `last=$(cat "$STAMP")` is then used unvalidated in
  `[ $(( now - last )) -lt 60 ]`: non-numeric content is an arithmetic error (no `set -e`,
  so the script continues to the restart), a huge value suppresses all restarts.
  `LOG=/tmp/resume-display-restore.log` grows unbounded and is also symlink-able (user
  context only).
- **Failure scenario:** `ln -s /etc/shadow /tmp/gamescope-hotplug-restart-stamp` by an
  unprivileged local process → root truncates/overwrites the target on next hotplug.
- **Fix:** Use `/run/gamescope-hotplug-restart-stamp` (root-only tmpfs) or
  `$XDG_RUNTIME_DIR`, validate with `[[ "$last" =~ ^[0-9]+$ ]] || last=0`, and log via
  `logger`/journal instead of a `/tmp` file.

### F13. `minecraftsplitscreen-test.sh`: hard-coded checkout path and an unbounded `git pull` on every Steam launch
- **Severity:** Low
- **Category:** hardcoded
- **File:** `minecraftsplitscreen-test.sh:7`, `minecraftsplitscreen-test.sh:10`
- **Status:** CONFIRMED
- **What:** `REPO_DIR="$HOME/MinecraftSplitscreenSteamdeck"` and
  `cd "$REPO_DIR" && git pull -q 2>/dev/null || true`. Launching a test from Steam mutates
  the checkout, with no timeout (a hung remote blocks the launch indefinitely, PRINCIPLES
  #6) and the `|| true` hides a failed `cd` too, after which `exec "$REPO_DIR/..."` fails
  with a bare "No such file". It also contradicts README §Developing ("git pull is not a
  deploy") — this script runs the *checkout's* launcher directly, so it bypasses
  `deploy.sh --check` entirely. `test` mode still exists in `minecraftSplitscreen.sh:1053`,
  so the script is live, not dead.
- **Failure scenario:** Deck offline / GitHub slow → Steam shows the game "running" with
  nothing on screen until the pull times out at the TCP layer.
- **Fix:** `REPO_DIR="${MCSS_REPO_DIR:-$HOME/MinecraftSplitscreenSteamdeck}"`, drop the
  auto-pull (or `timeout 20 git pull --ff-only`), and `cd "$REPO_DIR" || exit 1`.

### F14. Uninstaller's fetched Python helper is executed without integrity checks and cleaned up only if it landed under `/tmp`
- **Severity:** Low
- **Category:** security
- **File:** `uninstall-minecraft-splitscreen.sh:417-426`, `uninstall-minecraft-splitscreen.sh:438`, `uninstall-minecraft-splitscreen.sh:444`
- **Status:** CONFIRMED
- **What:** With no checkout, `remove-from-steam.py` is fetched from
  `${MCSS_REPO_RAW_URL:-https://raw.githubusercontent.com/.../main}` and run with
  `python3 "$helper"` — the env var can redirect it anywhere (same class as F9) and
  nothing verifies the file beyond `-s`. Cleanup is `[[ "$helper" == /tmp/* ]] && rm -f
  "$helper"`, but `mktemp -t` honours `$TMPDIR`, so with `TMPDIR` set (common in Flatpak/
  sandboxed shells) the downloaded script is leaked. The local `tmp` variable already
  holds the exact path — compare to that instead of a prefix.
- **Failure scenario:** `TMPDIR=~/.cache/tmp ./uninstall... --purge --yes` → helper left
  in `~/.cache/tmp/mcss-remove-from-steam.XXXX.py` after an uninstall whose purpose is
  "leave no trace".
- **Fix:** Hoist `tmp` to function scope and `[[ -n "$tmp" ]] && rm -f "$tmp"`; validate
  `MCSS_REPO_RAW_URL` starts with the expected host prefix, or embed a sha256 of the
  helper for the release ref.

### F15. `--keep-data` mode leaves most of "our" launcher tree behind; two of its targets are never created by this project
- **Severity:** Low
- **Category:** logic
- **File:** `uninstall-minecraft-splitscreen.sh:83-93`
- **Status:** CONFIRMED (grep of `modules/`, `minecraftSplitscreen.sh` finds no writer of `live.check` or `PolyMC-*.log`)
- **What:** Header says keep-data "removes launcher + shortcuts". `KEEP_DATA_TARGETS`
  removes `minecraftSplitscreen.sh`, the AppImage, icons and .desktop files, but not
  `$TARGET_DIR/modules/` (deployed by `runtime_deploy.sh:132`), `$TARGET_DIR/bin/evsieve`
  + `.evsieve.stamp` (`evsieve_management.sh`), or `$TARGET_DIR/java/`
  (`java_management.sh:176`, ~300 MB). Conversely `"$TARGET_DIR/live.check"` and
  `"$TARGET_DIR/PolyMC-*.log"` are not written by any file in this repo (PolyMC itself may
  write the log; `live.check` looks like a leftover from an older design).
- **Failure scenario:** User expects "launcher removed, worlds kept"; `du` shows the
  JDK and runtime modules still there; a later reinstall overwrites them anyway, so the
  gap is mostly disk + surprise.
- **Fix:** Add `"$TARGET_DIR/modules"`, `"$TARGET_DIR/bin"`, `"$TARGET_DIR/java"` to
  `KEEP_DATA_TARGETS` (all three are ours, not user data); drop or document `live.check`.

### F16. `deploy.sh`: non-atomic copies into a live tree, hard-coded `--help` line range, and a third env-var name for the same root
- **Severity:** Low
- **Category:** robustness
- **File:** `deploy.sh:44`, `deploy.sh:52`, `deploy.sh:186-187`, `deploy.sh:205-206`, `deploy.sh:212`
- **Status:** CONFIRMED
- **What:** (a) `cp "$src" "$dst"; chmod +x "$dst"` writes in place; a launcher that is
  mid-`source` (the Deck runs the deployed tree while you iterate) can read a truncated
  module. STYLE-GUIDE §7.9 asks for `tmp + mv`. (b) `sed -n '2,31p'` for `--help` is a
  hard-coded range that already stops at the "Version history" header line, printing the
  heading with no entries; any header edit silently changes the help text. (c) The deploy
  root is `MCSS_TARGET_DIR` here, `TARGET_DIR` in the uninstaller, and a readonly
  literal in the installer — three encodings of one datum (PRINCIPLES #9). (d) `mcss_stamp_apply
  ... || true` then unconditionally prints "stamped version=…" even when the sed failed.
- **Failure scenario:** `./deploy.sh` while a session is launching → half-copied
  `orchestrator.sh` sourced → syntax error → session dies with no obvious cause.
- **Fix:** `cp "$src" "$dst.tmp.$$" && chmod +x "$dst.tmp.$$" && mv -f "$dst.tmp.$$" "$dst"`;
  print help from a heredoc or up to a sentinel line; accept both `MCSS_TARGET_DIR` and
  `TARGET_DIR`; report the stamp failure.

### F17. CI/release hardening gaps: shellcheck scope, no job timeouts, no `permissions:`, unpinned third-party actions
- **Severity:** Low
- **Category:** robustness
- **File:** `.github/workflows/ci.yml:49`, `.github/workflows/ci.yml:56`, `.github/workflows/ci.yml:33-36`, `.github/workflows/release.yml:47`, `.github/workflows/release.yml:140`, `.github/workflows/release.yml:150`
- **Status:** CONFIRMED
- **What:** (a) The shellcheck gate covers `modules/*.sh minecraftSplitscreen.sh
  install-minecraft-splitscreen.sh` only — `uninstall-minecraft-splitscreen.sh`,
  `deploy.sh`, `minecraftsplitscreen-test.sh`, `system/deck-display-fixes/*.sh` and
  `tests/*.sh` are unchecked (local run: the system scripts carry two SC2034 warnings, no
  errors today). (b) Neither job sets `timeout-minutes`; a hung suite (the #80/#103 class
  the project already hit, PRINCIPLES #8) burns the 6 h default. (c) No `permissions:`
  block in either workflow — CI gets the default token scope it doesn't need; the release
  job needs `contents: write` and currently relies on the repo-level default (releases
  demonstrably work: v1.2.4 has all four assets, so this is a hygiene note, not a break).
  (d) `dtolnay/rust-toolchain@stable` and `softprops/action-gh-release@v2` are mutable
  refs; the evsieve binary users trust is produced by whatever those tags resolve to —
  the installer's sha256 check (`_evsieve_try_prebuilt`) verifies against a `.sha256`
  produced by the *same* job, so it proves transport integrity only. (e) `on: push:
  branches: ['**']` + `pull_request` runs every PR twice. (f) Secrets: only
  `secrets.GITHUB_TOKEN` is used — no third-party secrets, nothing echoed; fine.
- **Failure scenario:** (b) a test that inherits the capture pipe blocks the runner for
  6 h and every later push queues behind it.
- **Fix:** `timeout-minutes: 20` on both jobs; `permissions: {contents: read}` in ci.yml
  and `permissions: {contents: write}` in release.yml; pin actions by SHA; add the four
  standalone scripts and `system/**/*.sh` to the `-S error` gate; add
  `concurrency: {group: ci-${{ github.ref }}, cancel-in-progress: true}`.

### F18. Built-in mod defaults duplicate `mods.conf`, and the README install path guarantees the duplicate is the one used
- **Severity:** Low
- **Category:** hardcoded
- **File:** `install-minecraft-splitscreen.sh:378-398`, `mods.conf`, `README.md:60-63`
- **Status:** CONFIRMED
- **What:** `load_mods_config` looks for `${SCRIPT_DIR}/mods.conf`; README tells users to
  `wget` only the entry script, and curl|bash sets `SCRIPT_DIR` to the CWD, so for every
  end user the file is absent and the hard-coded arrays at 385-396 (7 mods × 3 parallel
  arrays + a `MODS` array) are what installs. `mods.conf` today lists the identical seven
  entries, but it is a second encoding (PRINCIPLES #9) that only checkouts read — an edit
  to `mods.conf` alone changes nothing for users, silently. `MOD_DEPS_BY_NAME` is dropped
  entirely on the default path.
- **Failure scenario:** Maintainer adds a mod or a dependency to `mods.conf`, Deck test
  from the checkout passes, release users never get it.
- **Fix:** Fetch `mods.conf` from `MCSS_REPO_RAW_URL` in the no-checkout case (it is
  already the pattern for `accounts.json`, `main_workflow.sh`), and make the built-in
  list a hard error/last-resort rather than a parallel table.

### F19. Installer quirks under curl|bash: `SCRIPT_DIR` = CWD picks up stray `modules/`/`mods.conf`; download loop leaks globals
- **Severity:** Info
- **Category:** robustness
- **File:** `install-minecraft-splitscreen.sh:101`, `install-minecraft-splitscreen.sh:263-268`, `install-minecraft-splitscreen.sh:199-200`, `install-minecraft-splitscreen.sh:214-215`
- **Status:** CONFIRMED
- **What:** Under `curl … | bash`, `$0` is `bash`, so `SCRIPT_DIR=$(cd . && pwd)` = the
  caller's CWD (documented at 97-100). If that directory happens to contain a `modules/`
  subdirectory (any project), line 267 `cp -r "$SCRIPT_DIR/modules/"* "$MODULES_DIR/"`
  copies it, the manifest is missing → "could not load the runtime module manifest" exit,
  or worse a partial set of same-named `.sh` files is sourced. `curl_output`,
  `curl_exit_code`, `wget_output`, `wget_exit_code` are assigned without `local` inside
  `download_modules` (STYLE-GUIDE §7.4).
- **Failure scenario:** `cd ~/projects/foo && curl … | bash` where foo has `modules/` →
  confusing "manifest missing" error instead of a download.
- **Fix:** Only treat `$SCRIPT_DIR/modules` as a checkout when
  `-f "$SCRIPT_DIR/modules/$RUNTIME_MANIFEST_NAME" && -f "$SCRIPT_DIR/minecraftSplitscreen.sh"`;
  declare the four temporaries `local`.

### F20. README / system README claims that no longer match the code
- **Severity:** Info
- **Category:** dead-code
- **File:** `README.md:68`, `system/deck-display-fixes/README.md:12`, `system/deck-display-fixes/README.md:13`
- **Status:** CONFIRMED
- **What:** (a) README: "Part way through it builds a small input helper (evsieve …) in a
  container" — since #126 the installer first fetches the prebuilt asset
  (`evsieve_management.sh:552-560`; v1.2.4 ships `evsieve-x86_64-linux` + `.sha256` +
  `.stamp`), so most installs never build. (b) `system/…/README.md` lists
  `predock-probe.sh (pre-existing, Deck-only)` as a component; it is not in the repo and
  `install.sh` never installs it. (c) The hotplug row's "only if MST probe failed" is
  contradicted by the code (see F7). Other README claims checked and consistent:
  `MCSS_CONTROLLER_PROXY` default 1 (`runtime_context.sh:210`), 4-player cap
  (`MCSS_MAX_PLAYERS=4`), Steam shortcut added (prompted, `system_integration.sh`),
  `deploy.sh --check` used by `tests/hardware/run_all.sh:86`.
- **Failure scenario:** Users wait for a "container build" that doesn't happen; a
  maintainer looks for `predock-probe.sh` to fix a boot race.
- **Fix:** Reword README line 68 ("downloads a prebuilt helper; builds it in a container
  only if that fails"); drop or add `predock-probe.sh`; fix the hotplug row per F7.

### F21. `install.sh` (deck fixes) assumes a live user session and has no uninstall
- **Severity:** Info
- **Category:** robustness
- **File:** `system/deck-display-fixes/install.sh:12`, `system/deck-display-fixes/install.sh:18`, `system/deck-display-fixes/install.sh:21`
- **Status:** CONFIRMED
- **What:** `systemctl --user daemon-reload` under `set -euo pipefail` aborts the script
  when run over a plain SSH login without `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS`
  (the very case the worker scripts guard against at `resume-display-restore.sh:16-17`),
  and it aborts *after* the user files were installed but *before* the `sudo install` of
  the root hook — a half install with no message beyond systemd's. `sudo` may prompt with
  no busy/wait indication (PRINCIPLES #6, minor). No matching uninstall exists for the
  `/etc/systemd/system-sleep` hook the project put there, so `uninstall-minecraft-
  splitscreen.sh --purge` ("leave no trace") leaves a root-owned hook that restarts
  gamescope on every docked resume (F8).
- **Failure scenario:** `ssh deck@deck 'cd …/deck-display-fixes && ./install.sh'` →
  "Failed to connect to bus" → exit 1 after copying two files.
- **Fix:** Export the two runtime vars at the top of `install.sh` the same way the worker
  does; add `uninstall.sh` (or a `--remove` flag) that `sudo rm`s the hook and disables
  the unit; mention the root hook in the main uninstaller's `--purge` notes.

### F22. `.gitignore` — no issues; two notes
- **Severity:** Info
- **Category:** robustness
- **File:** `.gitignore:3-5`, `.gitignore:13`
- **Status:** CONFIRMED
- **What:** `token.enc`, `*.log`, `*.tmp` are ignored; `git ls-files` shows no tracked
  `.log`/`.enc`/`ISSUES.md`, so nothing sensitive is committed. Note `*.log` is broad —
  a future test fixture named `*.log` would be silently untracked (a `!tests/**/*.log`
  exception is cheap if that ever happens). `ISSUES.md` being ignored is fine but is the
  only record that a private security doc exists; keep it out of any `git add -f` habit.
- **Failure scenario:** none today.
- **Fix:** none required.

---

## Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 2 (F1, F2) |
| Medium | 6 (F3, F4, F5, F6, F7, F8) |
| Low | 10 (F9–F18) |
| Info | 4 (F19–F22) |

**Top three:**

1. **F1 — full uninstall deletes `~/.local/share/PrismLauncher`**, a directory this
   project never creates and which commonly holds a Deck user's own Prism instances and
   worlds. One-line removal from `FULL_TARGETS`; the blast-radius principle the same file
   cites for podman is being violated for user data.
2. **F2 — the CI gate cannot see up to five regressions in `test_uhid_pad.sh`** (23 tests,
   baseline 18) and discards every suite's exit code even though 17/19 suites now exit
   non-zero on failure. Gate on exit status with an explicit known-fail allowlist.
3. **F3 — release-asset installers fetch modules from unpinned `main`** with no integrity
   check, so a tagged release is neither reproducible nor isolated from later pushes; bake
   `REPO_REF` into the uploaded asset in `release.yml`. Pair with **F4** (Ctrl-C is
   swallowed by the `INT`/`TERM` trap, and after it fires the deployed modules quietly come
   from the network instead of the checkout).
