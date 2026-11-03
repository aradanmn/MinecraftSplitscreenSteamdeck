# Review C — installer: mods / versions / java / launcher / deploy / utilities

Files read in full: `modules/mod_management.sh` (2214), `modules/version_management.sh` (505),
`modules/java_management.sh` (449), `modules/launcher_setup.sh` (139),
`modules/runtime_deploy.sh` (205), `modules/version_stamp.sh` (155),
`modules/utilities.sh` (369), `mods.conf`, `accounts.json`. Cross-traced:
`install-minecraft-splitscreen.sh` (constants block, `load_mods_config`, `download_modules`),
`modules/main_workflow.sh` (call order), `modules/instance_creation.sh:330-510`
(consumer of `MOD_URLS`/`FINAL_MOD_INDEXES`), `modules/preflight.sh:146` (jq is a hard
requirement).

Context that matters for several findings: the installer entry runs `set -euo pipefail`
and the modules deliberately inherit it (`install-minecraft-splitscreen.sh:24-27`).
`main_workflow.sh:94-104` calls `download_prism_launcher`, `get_minecraft_version`,
`detect_java`, `configure_polymc_defaults`, `get_fabric_version`, `get_lwjgl_version` as
plain statements (not inside `if`/`||`), so `errexit` is LIVE inside them.

Findings marked CONFIRMED-by-test were reproduced with small scripts in the scratchpad
(`t1.sh`–`t4.sh`); outbound network is proxied/blocked here, so API-shape claims are
marked PLAUSIBLE.

---

## High

### C1. Documented offline fallbacks in `get_fabric_version` and `get_required_java_version` are unreachable — a transport failure aborts the installer under `set -e`
- **Severity:** High
- **Category:** bug (set -e pitfall)
- **File:** `modules/version_management.sh:404-411`, `modules/java_management.sh:114-120`, `modules/java_management.sh:135-141`
- **Status:** CONFIRMED (reproduced: `t1.sh` — installer exits 56 with a bare `curl: (6)` line; "FALLBACK REACHED" never prints)
- **What:** Both functions do a plain assignment from a command substitution whose pipeline fails on any transport error, e.g.
  ```bash
  FABRIC_VERSION=$(fetch_url "${FABRIC_META_BASE}/versions/loader" - \
      | jq -r '.[0].version' 2>/dev/null)
  # Fallback to known stable version if API call fails   <- never reached
  ```
  and `manifest_json=$(fetch_url "$manifest_url" - 2>/dev/null)` / `version_json=$(fetch_url "$version_url" - 2>/dev/null)`. In `-` mode `fetch_url` has no `-f`, so an HTTP error still returns 0 — but DNS/connect/`--max-time` failures return non-zero, `pipefail` propagates it through `jq`, the assignment fails, and `errexit` kills the process. `get_required_java_version` runs inside `$(...)` at `java_management.sh:358`, so the subshell dies and the outer assignment in `detect_and_install_java` dies too. The explicit `_mc_version_to_java_major` "offline fallback table" (#48) and the `FABRIC_VERSION="0.16.9"` fallback are therefore dead on exactly the failure they exist for.
- **Failure scenario:** Transient DNS hiccup / Wi-Fi drop / 15 s stall on `meta.fabricmc.net` after the version was picked -> installer exits with only curl's one-line stderr; no `print_error`, no fallback, instances not created. Same for `piston-meta.mojang.com` during Java detection.
- **Fix:** Make the capture errexit-safe at each site: `FABRIC_VERSION=$(fetch_url ... - 2>/dev/null | jq -r '.[0].version' 2>/dev/null) || FABRIC_VERSION=""` (and the same `|| manifest_json=""` / `|| version_json=""` in java_management). Consider a shared `fetch_url_body_or_empty` helper so this isn't re-fixed per site (PRINCIPLES #9). Lower-impact siblings of the same pattern: `launcher_setup.sh:73-84` (`prism_url=$(fetch_url ... | jq | head)` — the `print_error` at :88 never fires on transport failure) and `version_management.sh:84-92` (`mojang_versions=` inside the `$(get_supported_minecraft_versions)` subshell — the specific "Could not fetch Minecraft versions" message is never shown; the caller prints the generic one at :336).

### C2. `download_and_install_jdk` picks the wrong extracted JDK when another major is already installed, then reports success without validating the version
- **Severity:** High
- **Category:** logic
- **File:** `modules/java_management.sh:245`, `modules/java_management.sh:255-256`, `modules/java_management.sh:411-421`
- **Status:** CONFIRMED (`t4.sh`: `find | sort -V | tail -1` over `jdk-21.0.4+7`,`jdk-25.0.1+9` returns `jdk-25.0.1+9`)
- **What:** After extracting into the SHARED `$TARGET_DIR/java`, the "extracted dir" is located as
  ```bash
  jdk_dir=$(find "$install_dir" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)
  ...
  export "${java_home_var}=${jdk_dir}"      # JAVA_21_HOME=.../jdk-25.0.1+9
  ```
  i.e. the highest-versioned directory present, not the one just extracted. `find_java_installation` then returns `${JAVA_21_HOME}/bin/java` FIRST (`:276-281`) with no version probe, and the post-install branch in `detect_and_install_java` (`:411-421`) prints "Java 21 automatically installed and configured!" without calling `_java_output_matches_major` (the pre-install branch at `:370-392` does).
- **Failure scenario:** User installed for MC 26.x earlier (jdk-25 under `$TARGET_DIR/java`), re-runs the installer choosing MC 1.20.4 (Java 17) or uses the custom-mod version switch (`mod_management.sh:1894 detect_java`). jdk-17 is downloaded and extracted, but `JAVA_17_HOME` is exported as the jdk-25 dir; `polymc.cfg`/instance.cfg get Java 25 for a game that expects 17; the installer says success.
- **Fix:** Determine the extracted directory from the tarball itself (`tar -tzf "$tarball" | head -1 | cut -d/ -f1`) or extract into a fresh temp dir and move; and run `_java_output_matches_major` on the post-install path exactly as on the pre-install path.

---

## Medium

### C3. Re-install is not atomic: a failed fetch deletes the working launcher and can leave truncated runtime modules in the deployed tree
- **Severity:** Medium
- **Category:** robustness
- **File:** `modules/runtime_deploy.sh:72-82`, `modules/runtime_deploy.sh:171-185`
- **Status:** CONFIRMED
- **What:** `setup_splitscreen_launcher_script` downloads straight onto the live path and, on a bad result, removes it:
  ```bash
  fetch_url "$remote_script" "$launcher_script" || true
  ...
  if [[ ! -s "$launcher_script" ]] || ! head -n1 "$launcher_script" | grep -q '^#!'; then
      ...
      rm -f "$launcher_script" 2>/dev/null || true
      return 1
  ```
  `install_runtime_modules` likewise `cp`/`fetch_url`s each module directly to `$dest_dir/$mod`. curl `-o` creates/truncates the target before the transfer completes, so a 404 (bad `REPO_REF`), a mid-transfer drop, or `--max-time 15` expiring leaves a previously working install with no launcher (deleted) and/or a partial module, and the installer aborts (`main_workflow.sh:172-173`).
- **Failure scenario:** `REPO_REF=typo ./install-...` on a Deck that already has a working install -> launcher removed, Steam shortcut now points at nothing.
- **Fix:** Fetch to `mktemp` in the same directory, validate, then `mv` (STYLE-GUIDE §7.9 "atomic writes via tmp + mv"); stage all modules and swap the directory only after every download succeeded.

### C4. Eleven raw `curl`/`wget` CurseForge sites bypass the "one transport", most with NO timeout — unbounded waits and drifted limits (15 / 12 / none)
- **Severity:** Medium
- **Category:** principle-violation (#6 bounded waits, #9 one encoding; ARCHITECTURE §2 "raw curl/wget allowed ONLY in the pre-utilities bootstrap")
- **File:** `modules/mod_management.sh:476` (timeout 15), `:828` (none), `:976,:993,:1014` (none), `:1135` (none), `:1232` (none), `:1455` (-m 12), `:1547` (-m 15), `:1676` (none); `modules/version_management.sh:254` (none); `modules/java_management.sh:211` (none, bulk — acceptable); `modules/launcher_setup.sh:94` (none)
- **Status:** CONFIRMED
- **What:** `fetch_url`/`fetch_url_status` have no header support, so every authenticated CurseForge call re-implements transport, e.g. `version_management.sh:254`:
  ```bash
  http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_body" -H "x-api-key: $cf_api_key" "$cf_api_url")
  ```
  with no `--max-time`. This is the exact drift #51 D14 fixed for the unauthenticated sites, now reproduced for the authenticated ones. `version_management.sh:254` runs inside the 20-version scan, so one stalled connection hangs the installer with no spinner or countdown (#6).
- **Failure scenario:** Any CurseForge mod in `mods.conf` (or a custom CF mod) + a stalled TCP connection -> installer sits silently forever at "Testing 1.21.x...".
- **Fix:** Extend `fetch_url`/`fetch_url_status` with an optional header-file argument (`curl -H @"$hdrfile"`) and route all 11 sites through them with one timeout constant (`MCSS_API_TIMEOUT_S`).

### C5. Mod jars are downloaded with no integrity verification although both APIs return hashes in the same response
- **Severity:** Medium
- **Category:** security
- **File:** `modules/mod_management.sh:190-199` (`_modrinth_tier_match` captures only `.url`), `:329-331` (`match_curseforge_version` captures only `.downloadUrl`), consumer `modules/instance_creation.sh:501`
- **Status:** CONFIRMED (`grep -n "hashes\|sha1\|sha512" modules/mod_management.sh modules/instance_creation.sh` -> no hits)
- **What:** Modrinth `files[].hashes.sha1/sha512` and CurseForge `hashes[]` are present in the responses already parsed, but only the URL is retained in `MOD_URLS`; `instance_creation.sh` then `fetch_url "$mod_url" "$mod_file" 0` with no check. Contrast `java_management.sh:217-229`, which does verify the JDK SHA-256. A truncated CDN response or a tampered redirect target yields a corrupt/foreign jar that only surfaces as a Fabric crash at first launch.
- **Failure scenario:** CDN 200 with a truncated body (connection reset after headers) -> `Sodium.jar` half-written, `fetch_url` returns 0 (curl only fails on HTTP status), instance 1 crashes on launch and the mods dir is copied to instances 2-4.
- **Fix:** Extend the `"<url>\t<deps>"` match contract to `"<url>\t<sha512>\t<deps>"` (Modrinth) / sha1 (CF `hashes[] | select(.algo==1)`), store in a parallel `MOD_HASHES` array, and verify with `sha512sum`/`sha1sum` after download before accepting the file.

### C6. `detect_and_install_java` sources the user's `~/.profile` into the installer — can kill the run under `set -u` (and runs arbitrary user shell code)
- **Severity:** Medium
- **Category:** bug / security
- **File:** `modules/java_management.sh:366`, `modules/java_management.sh:408`
- **Status:** CONFIRMED (reproduced: `t3.sh` — a `.profile` line `export FOO="$UNSET_THING"` exits the script with 1 despite `|| true`; "SURVIVED" never prints)
- **What:**
  ```bash
  [[ -f ~/.profile ]] && source ~/.profile 2>/dev/null || true
  ```
  The `|| true` does not protect against expansion errors: under `set -u` an unbound-variable reference in `.profile` is a shell error, not a command failure, and the non-interactive shell exits. The comment ("to get any existing Java environment variables") is vestigial — #41 removed the `~/.profile` edits and `download_and_install_jdk` now exports in-process (`:252-256`), so nothing is gained. `.profile` may also `exec`, change `PATH`/`IFS`, or run interactive-only commands.
- **Failure scenario:** Any Deck user whose `.profile` references `$SSH_AGENT_PID`-style variables that aren't set in the installer's environment -> installer dies at "Searching for Java …" with a one-line `unbound variable` message.
- **Fix:** Delete both `source ~/.profile` lines.

### C7. `mcss_stamp_apply` uses unescaped values in `sed s///` — the documented `REPO_REF=feat/...` form breaks stamping, and `&`/`\` inject
- **Severity:** Medium
- **Category:** bug (sed injection)
- **File:** `modules/version_stamp.sh:71-75`; producer `modules/runtime_deploy.sh:95-96` + `modules/version_stamp.sh:147-148`
- **Status:** CONFIRMED (reproduced: `t2.sh` — `ref:feat/gamescope-windowing` -> `sed rc=1`, file unstamped; `a&b` -> `a__MCSS_COMMIT__b`)
- **What:**
  ```bash
  sed -i -e "s/__MCSS_VERSION__/${version}/" \
         -e "s/__MCSS_COMMIT__/${commit}/" \
         -e "s|__MCSS_BUILD_DATE__|${date}|" "$file"
  ```
  #170 sets `commit="ref:${fallback_ref}"` where `fallback_ref` is the user-supplied `REPO_REF`. The installer's own documented example is `REPO_REF=feat/gamescope-windowing` (`install-minecraft-splitscreen.sh:105-107`); the `/` terminates the `s` command, sed fails, and the launcher is left reporting `dev/unknown` — the very outcome #170 set out to fix — with only a warning. `&` in any value re-inserts the match; `\` sequences are interpreted.
- **Failure scenario:** Every curl|bash install from a branch ref containing `/` (all `feat/`, `fix/`, `refactor/` branches) stamps nothing.
- **Fix:** Escape before use (`_sed_escape() { printf '%s' "$1" | sed -e 's/[\/&|\\]/\\&/g'; }`), or avoid sed entirely: read the file into a variable and use `${content//__MCSS_COMMIT__/$commit}`.

### C8. PolyMC AppImage: raw `wget -O` with no checksum, and a failed download permanently satisfies the "already present" check
- **Severity:** Medium
- **Category:** bug / security
- **File:** `modules/launcher_setup.sh:62`, `modules/launcher_setup.sh:94-95`
- **Status:** CONFIRMED
- **What:**
  ```bash
  if [[ -f "$TARGET_DIR/PolyMC.AppImage" ]]; then   # :62 — -f, not -s / -x
  ...
  wget -O "$TARGET_DIR/PolyMC.AppImage" "$prism_url" # :94 — raw wget, no fetch_url, no timeout
  chmod +x "$TARGET_DIR/PolyMC.AppImage"
  ```
  `wget -O` creates the file before transferring; on failure (or on a curl-only system where `wget` doesn't exist, `set -e` aborts here after the file exists) a 0-byte or partial `PolyMC.AppImage` remains, and every subsequent run says "PolyMC AppImage already present". No size/hash validation of the ~30 MB binary that will be executed. Also hard-codes `PolyMC/PolyMC` releases (IMPROVEMENTS-ANALYSIS-2026-08-15 §"Abstract launcher detection" already tracks the launcher abstraction; the integrity/partial-file issue is not covered there).
- **Failure scenario:** Wi-Fi drops at 40% -> partial AppImage -> installer aborts (`set -e`); re-run skips download, later `get_prism_executable` returns the broken file and PolyMC "fails to start" with no pointer to the cause.
- **Fix:** `fetch_url "$prism_url" "$tmp" 0 && mv "$tmp" "$TARGET_DIR/PolyMC.AppImage"`; gate the skip on `-s` plus a sanity check (`head -c4 | grep -q $'\x7fELF'`); optionally verify the GitHub release's digest if published.

### C9. Version scan re-downloads every required mod's FULL version list once per candidate MC version (20 × N calls), and any 429/transport error silently marks the version — or the required mod — "not compatible"
- **Severity:** Medium (fail-closed part PLAUSIBLE)
- **Category:** robustness / principle-violation (#5 fail-open)
- **File:** `modules/version_management.sh:98`, `:111-125`, `:189-207`; `modules/mod_management.sh:380-389`, `:1872` + `:1888`
- **Status:** CONFIRMED (redundant fetches); PLAUSIBLE (rate limiting — Modrinth's documented limit is 300 req/min; confirm by running the scan with `--debug` and watching for `http_code=429`)
- **What:** For each of `all_versions[@]:0:20`, `check_mod_version_compatibility` fetches `${MODRINTH_API_BASE}/project/$mod_id/version` again — the same URL, same body (Sodium's list is hundreds of versions) — 20 × 7 = 140 fetches for the default `mods.conf`. Any non-200 (`:205-207`) returns 1 = "incompatible": the version silently disappears from the list. In `check_modrinth_mod` a non-200 is also "not compatible … (API error)" and the REQUIRED mod is simply absent from `SUPPORTED_MODS` — the install proceeds and only `instance_creation.sh` prints "CRITICAL … continuing". The custom-mod version-switch path runs the whole scan twice back-to-back (`mod_management.sh:1872` then `:1888` → `get_minecraft_version`).
- **Failure scenario:** A brief rate limit or 5xx during "Testing 1.21.5…" -> 1.21.5 is not offered, no message says why; or Sodium gets a 429 in `check_mod_compatibility` -> a 4-up game ships without its performance baseline.
- **Fix:** Fetch each required mod's version list ONCE (cache body per mod id in a temp dir or assoc array) and evaluate all 20 candidates against it; treat non-200/000 as "unknown" (retry once with backoff, then surface an explicit "could not verify" line rather than "incompatible").

### C10. `fetch_and_add_external_mod` adds Modrinth dependencies with no compatibility check; the downstream URL resolver then falls back to "any Fabric release" and installs a jar for the wrong MC version
- **Severity:** Medium
- **Category:** logic (cross-module contract)
- **File:** `modules/mod_management.sh:1096-1109` (adds with `MOD_URLS+=("")`), consumer `modules/instance_creation.sh:436-441`
- **Status:** CONFIRMED
- **What:** The Modrinth branch fetches `/project/<id>` (metadata only), takes `.title`, and appends the mod with an empty URL "to be resolved during download". `instance_creation.sh` then walks its own ladder and, when nothing matches, does:
  ```bash
  # If still no URL found, try the latest Fabric version for any compatible release
  mod_url=$(... jq -r '.[] | select(.loaders[] == "fabric") | ... .url' | head -n1)
  ```
  — the newest Fabric build regardless of `game_versions`. So a transitive dependency that has no build for `MC_VERSION` is not skipped; a build for some other MC version is installed and copied to all four instances.
- **Failure scenario:** A custom mod requires library X whose newest build is for 1.21.1 while the selected version is 1.21.5 -> X-1.21.1.jar installed -> Fabric loader refuses to start ("incompatible mod set").
- **Fix:** In `fetch_and_add_external_mod`, run `match_modrinth_version` against `/project/<id>/version` and store the resolved URL (or skip with a warning) — the ladder already exists (#88); delete the "any release" tier in `instance_creation.sh`.

### C11. Version filter and mod scan use different ladders, so a version can be offered and then fail for the same required mod
- **Severity:** Medium
- **Category:** logic
- **File:** `modules/version_management.sh:223-224` (`match_modrinth_version … 0`), `:274-278` (`allow_fallback=1` unconditionally) vs `modules/mod_management.sh:401` (`… 1`) and `:500-515` (guarded)
- **Status:** [KNOWN: docs/TODO.md:33-35 "three pre-existing divergences preserved by parameter"] — reporting because the consequence is user-visible
- **What:** `get_supported_minecraft_versions` accepts a version if the weaker guard (`check_standalone=0`, CF fallback never gated) finds a match; `check_mod_compatibility` then applies the stronger guard. Where they differ (a standalone `1.21` release exists → fallback blocked only in the strong one), the version is listed as "All required mods compatible" and the subsequent scan reports the required mod as incompatible. Also, with `check_standalone=1` the `$mc_major_minor` tier of `match_modrinth_version` (`:260`) can never succeed: `standalone` is non-empty exactly when a Fabric version lists `$mm`, which is the only case that tier could match — so the tier is effectively dead in the strong path.
- **Failure scenario:** Mod publishes `game_versions: ["1.21"]` only; target 1.21.3. Filter: no standalone check → `1.21` tier matches → "compatible". Scan: standalone found → fallback blocked → "no compatible Fabric version" → required mod missing.
- **Fix:** Pick one policy (the strong one) and pass the same `check_standalone`/`allow_fallback` at both sites; open the issue the #88 comment anticipates.

---

## Low

### C12. Required-mod detection is a PREFIX match — any optional mod whose name starts with a required mod's name becomes required/hidden
- **Severity:** Low (latent — all `mods.conf` entries are currently `required`)
- **Category:** logic
- **File:** `modules/mod_management.sh:1984`, `:2102`; same pattern in `modules/instance_creation.sh:470`
- **Status:** CONFIRMED
- **What:** `if [[ "${SUPPORTED_MODS[$i]}" == "$req"* ]]` — glob prefix. `mods.conf`'s own examples ("Reese's Sodium Options", "Sodium Options API", `:2118`) start with "Sodium".
- **Failure scenario:** Add `optional|Sodium Extra|modrinth|...` -> it is never listed for selection and is force-installed; `MISSING_MODS` classification in instance_creation also flips to CRITICAL.
- **Fix:** Exact compare (`== "$req"`), or better, compare by `(platform,id)` via `REQUIRED_SPLITSCREEN_IDS`.

### C13. Predictable `/tmp` path in `get_lwjgl_version` (symlink / pre-plant)
- **Severity:** Low
- **Category:** security
- **File:** `modules/version_management.sh:446`
- **Status:** CONFIRMED (same class as BUG-AUDIT-2026-06-24-followup N6, which lists other sites; this one is not listed there)
- **What:** `local temp_file="/tmp/fabric_versions_$$.json"` then `fetch_url "$fabric_game_url" "$temp_file"` — `curl -o` follows a pre-planted symlink and writes as the user; `$$` is guessable. Every other site in these modules uses `mktemp`.
- **Fix:** `temp_file=$(mktemp)`.

### C14. CurseForge API key exposed in process argv at every call; key file briefly world-readable
- **Severity:** Low
- **Category:** security
- **File:** `modules/mod_management.sh:476,828,976,993,1014,1135,1232,1455,1547,1676`; `modules/version_management.sh:254`; `modules/utilities.sh:198-200`
- **Status:** CONFIRMED
- **What:** `-H "x-api-key: $cf_api_key"` puts the secret in `/proc/<pid>/cmdline` for the duration of each request (readable by any local process; `ps` on a multi-user box). `resolve_curseforge_api_token` writes the key with `printf '%s\n' "$key" > "$CURSEFORGE_KEY_FILE"` under the default umask and only then `chmod 600`. curl `-L` also forwards custom headers to a different host on redirect (only `Authorization` is stripped), so a redirect off `api.curseforge.com` would leak it.
- **Fix:** Write the header to a 0600 temp file and pass `-H @"$hdr"`; `(umask 077; printf … > "$file")`; drop `-L` for API calls.

### C15. jq program built by string interpolation of `MC_VERSION`
- **Severity:** Low
- **Category:** security (jq injection pattern) / robustness
- **File:** `modules/mod_management.sh:916-923`
- **Status:** CONFIRMED
- **What:** `jq -r ". [] | select(.game_versions[]? | (. == \"$MC_VERSION\" or . == \"$mc_major_minor\" …"` — every other site uses `--arg`. `MC_VERSION` comes from the Mojang manifest (release ids are numeric-dotted) or a numeric menu index, so not currently exploitable, but a `"` in either would change the program. Also, the grep-based "no jq" fallback right below (`:924-931`) is unreachable: `:903` already ran `jq -e .` and returned, and preflight hard-requires jq.
- **Fix:** `--arg v "$MC_VERSION" --arg mm "$mc_major_minor"`; delete the else-branch.

### C16. Dead code: `resolve_mod_dependencies` + `resolve_modrinth_dependencies` + `resolve_curseforge_dependencies` have no callers and are a 4th/5th ladder copy
- **Severity:** Low
- **Category:** dead-code / principle-violation (#9)
- **File:** `modules/mod_management.sh:680-864`
- **Status:** CONFIRMED (`grep -rn` across repo: only the definitions and the dispatcher's own two calls)
- **What:** ~185 lines including yet another exact→major.minor→.x Modrinth ladder and an unguarded CF combined query, listed as Public API in the header. They will drift from `match_*_version` (already do: no `.0` tier, no guard). Same file also carries jq-less `grep` fallbacks at `:1090-1094` (unreachable: preflight requires jq) and a `"DOUdJVEm"` (Controlify, a MODRINTH id) entry inside the CurseForge fallback-name table at `:1159-1162`.
- **Fix:** Delete all three functions and the header lines; delete the jq-less branches; remove the DOUdJVEm case.

### C17. `resolve_curseforge_dependencies_api` makes three API calls where one suffices, and the first response is never read
- **Severity:** Low
- **Category:** robustness / dead-code
- **File:** `modules/mod_management.sh:970-1031`
- **Status:** CONFIRMED
- **What:** Fetches `/mods/<id>` into `temp_file` but only tests `[[ -s "$temp_file" ]]`; then `/mods/<id>/files`, picks a file id, then `/mods/<id>/files/<fid>` for `.data.dependencies`. The `/files` response already includes `dependencies[]` per file (the sibling at `:851-856` reads them from there). Three unbounded curls (C4) plus a hard-coded `"238222") dependencies="306612"` (JEI→Fabric API, "legacy 1.21.1 era") that will never be exercised for a Fabric splitscreen install.
- **Fix:** One `/files?modLoaderType=4&gameVersion=$MC_VERSION` call and read `.dependencies` from the matched file; drop the `/mods/<id>` fetch and the JEI special case.

### C18. `fetch_and_add_external_mod` CurseForge branch always "succeeds", even with no key, no name, and no URL
- **Severity:** Low
- **Category:** logic (return contract)
- **File:** `modules/mod_management.sh:1156-1188`
- **Status:** CONFIRMED
- **What:** Header says "return 1 if nothing could be added", but the CF branch unconditionally appends `"External Dependency (CF:$ext_mod_id)"` with `MOD_URLS+=("$download_url")` (possibly empty) and sets `success=true`. `resolve_all_dependencies:656-657` then logs "Successfully added external dependency" for a placeholder that will be reported missing at download time. With no API key at all (`:1126` false), the same placeholder is added.
- **Fix:** Only append when `download_url` (or at least `mod_title`) was resolved; return 1 otherwise.

### C19. Modrinth ladder picks the newest matching version regardless of `version_type` and requires `primary == true`
- **Severity:** Low
- **Category:** logic
- **File:** `modules/mod_management.sh:190-193`, `:1612`
- **Status:** CONFIRMED (behaviour); the "no primary file" case per Modrinth API docs ("If there are no primary files listed, the first file should be taken as the primary")
- **What:** `.[] | select(...) | .files[] | select(.primary == true) | .url | head -n1` — Modrinth returns newest-first, so an alpha/beta build for the target MC beats an older release build (no `select(.version_type=="release")`), and a version whose files carry no `primary` flag is treated as no match. `instance_creation.sh:419` uses the more tolerant `(.files | map(select(.primary)) | .[0].url) // (.files[0].url)` — a divergence between the two encodings (H13 in BUG-AUDIT-2026-06-24-followup fixed only the instance_creation side). Also the `select(.game_versions[] == $v and (.loaders[] == "fabric"))` cartesian form emits the version once per true pair, so `dep_ids` can contain duplicates (`"P7dR8mSH P7dR8mSH "`); harmless today because `add_mod_dependencies` de-dups by index.
- **Fix:** Prefer `version_type=="release"` first, fall back to any; use the `// (.files[0].url)` form in `_modrinth_tier_match`; use `any(...)` instead of `[] ==`.

### C20. `get_fabric_version` takes `.[0]` (may be an unstable loader) and pins a stale fallback
- **Severity:** Low
- **Category:** hardcoded / logic
- **File:** `modules/version_management.sh:404-410`
- **Status:** PLAUSIBLE (Fabric meta `/versions/loader` entries carry `stable: true|false`; whether an unstable entry can be first depends on the feed at the time — verify with `curl -s https://meta.fabricmc.net/v2/versions/loader | jq '.[0]'`)
- **What:** `jq -r '.[0].version'` with no `select(.stable)`; fallback `FABRIC_VERSION="0.16.9"` is a magic literal that will age (and is unreachable anyway — C1).
- **Fix:** `jq -r '[.[] | select(.stable)][0].version // .[0].version'`; name the fallback at the installer constants block.

### C21. `get_lwjgl_version` API lookup reads a field Fabric meta does not publish; the static table is what always runs
- **Severity:** Low
- **Category:** dead-code / hardcoded
- **File:** `modules/version_management.sh:445-455`, `:482-505`
- **Status:** PLAUSIBLE (network blocked here; `/v2/versions/game` is documented as `[{version, stable}]` — confirm with `curl -s https://meta.fabricmc.net/v2/versions/game | jq '.[0]'`)
- **What:** `.[] | select(.version == $mc_ver) | .lwjgl // empty` — if `.lwjgl` is absent the function always falls through to `get_lwjgl_version_by_mapping`, whose values (`3.4.1` for 26.x "required by Sodium", default `3.3.3`) are hand-maintained and baked into `mmc-pack.json` (`instance_creation.sh:86-96`). The API call is then a wasted network round-trip on the critical path. Mojang's per-version manifest (already fetched in `get_required_java_version`) contains the real LWJGL version in its `libraries[]`.
- **Fix:** Derive LWJGL from the Mojang version JSON (`.libraries[].name | select(startswith("org.lwjgl:lwjgl:")) | split(":")[2]`), keep the table as offline fallback only, and make `download`/`jq` consistent with that.

### C22. Offline Java table is wrong for MC 1.20.5 / 1.20.6 (Java 21, not 17)
- **Severity:** Low
- **Category:** hardcoded
- **File:** `modules/java_management.sh:85-86`
- **Status:** CONFIRMED (Mojang raised the requirement to Java 21 at 1.20.5)
- **What:** `^1\.(1[8-9]|20)(\.|$)` -> `17`. Only matters when the manifest is unreachable (and see C1 — currently that path aborts anyway).
- **Fix:** Split `1.20.5+` into the 21 bucket, or drop the table and require the manifest.

### C23. Version menu lists 10 but accepts 1-20; "verified to support … Controlify" line is hard-coded and stale
- **Severity:** Low
- **Category:** bug / hardcoded
- **File:** `modules/version_management.sh:347-353`, `:355-356`, `:364`, `:380`
- **Status:** CONFIRMED
- **What:** Loop prints `counter -le 10`, prompt says `1-${#supported_versions[@]}` (up to 20) and the validator accepts up to 20 — choosing 14 silently selects an unlisted version. `:355-356` prints a fixed "✅ Controlify (controller support)" although `mods.conf` now has seven required mods and `mod_management.sh:1938` already has `_required_mods_summary` for exactly this (the comment there says it "used to always say Controlify").
- **Fix:** Cap the accepted range to what was printed (or print all); reuse `_required_mods_summary`.

### C24. Consumer-side literal re-embeds (API bases ×17, `$HOME/.local/share/PolyMC` ×3) and unnamed magic numbers
- **Severity:** Low
- **Category:** hardcoded / principle-violation (ARCHITECTURE §3 "a consumer-side `:-fallback` re-embeds the literal")
- **File:** `modules/mod_management.sh` (`https://api.modrinth.com/v2` ×7, `https://api.curseforge.com/v1` ×10), `modules/version_management.sh:189` (no fallback, inconsistent with the rest), `modules/java_management.sh:176,287,399` (`${TARGET_DIR:-$HOME/.local/share/PolyMC}`), `java_management.sh:177` (`arch="x64"`), `version_management.sh:98` (20), `mod_management.sh:1512,1557` (30), `:476` (15), `:1455` (12), `:1547` (15), `launcher_setup.sh:127` (`ConfigVersion=1.2`), `java_management.sh:111` + `version_management.sh:85` (manifest URL twice)
- **Status:** CONFIRMED
- **What:** The installer entry already exports `MODRINTH_API_BASE`/`CURSEFORGE_API_BASE` (`install-minecraft-splitscreen.sh:120-122`) and `TARGET_DIR`; the `:-` copies can drift independently (the exact 1280/800 / 3072 pattern ARCHITECTURE cites). The Mojang manifest URL is typed in two modules.
- **Fix:** Bare `$MODRINTH_API_BASE` etc. in consumers; `MCSS_MOJANG_MANIFEST_URL`, `MCSS_VERSION_SCAN_DEPTH=20`, `MCSS_API_TIMEOUT_S` at the installer constants block.

### C25. Built-in `mods.conf` fallback in the installer duplicates the file without a PAIRED marker
- **Severity:** Low
- **Category:** principle-violation (#9; ARCHITECTURE §1 "documented duplication budget")
- **File:** `install-minecraft-splitscreen.sh:384-396` vs `mods.conf:28-46`
- **Status:** CONFIRMED (`grep -n PAIRED install-minecraft-splitscreen.sh` shows markers only for the runtime_context block)
- **What:** Seven ids/names retyped; curl|bash installs use this copy "by design" (`:100`), so an edit to `mods.conf` alone (e.g. the ModernFix→mVUS fork swap the file's comment warns about) silently doesn't reach curl|bash users.
- **Fix:** Either fetch `mods.conf` from `MCSS_REPO_RAW_URL` like `accounts.json`, or add the `# PAIRED WITH mods.conf` comment on both sides.

### C26. Temp files without traps; `local x=$(mktemp)` masks mktemp failure (6 sites)
- **Severity:** Low
- **Category:** robustness (STYLE-GUIDE §7.9)
- **File:** `modules/mod_management.sh:973,990,1011,1069,1132,1229`; every `mktemp` site in mod_management/version_management (no `trap`)
- **Status:** CONFIRMED
- **What:** Ctrl-C during any of the ~20 API calls leaks the temp file; SC2155 sites lose the mktemp status (`temp_file=""` → `curl -o ""`).
- **Fix:** One module-level temp dir created with `mktemp -d` and an EXIT trap in the installer entry; `local f; f=$(mktemp) || return 1`.

### C27. Function-scope leaks: `MOD_NAME/MOD_TYPE/MOD_ID` set as globals; `dep_platform`, `dep_id`, `i`, `deps`, `dep_arr`, `idx`, `j` not `local`
- **Severity:** Low
- **Category:** robustness (STYLE-GUIDE §7.4)
- **File:** `modules/mod_management.sh:123`, `:609-627`, `:2164-2170`, `:2202`
- **Status:** CONFIRMED
- **What:** `IFS='|' read -r MOD_NAME MOD_TYPE MOD_ID <<< "$mod"` creates upper-case globals one letter away from the `MOD_TYPES`/`MOD_IDS` arrays; `read -a dep_arr` (no `-r`, not local).
- **Fix:** `local mod_name mod_type mod_id` etc.

### C28. `fetch_and_add_external_mod` treats any body containing the string `"error"` as an API error
- **Severity:** Low
- **Category:** logic
- **File:** `modules/mod_management.sh:1082`
- **Status:** CONFIRMED
- **What:** `if ! grep -q '"error"' "$temp_file"` on the whole project JSON — a description/body containing the quoted word skips a legitimate dependency. Use `jq -e '.error? // empty'`.

### C29. Modrinth slugs and ids are treated as different mods
- **Severity:** Low
- **Category:** logic
- **File:** `modules/mod_management.sh:1372-1376`, `:1391-1403`, `:631-632`
- **Status:** PLAUSIBLE (needs a live run: add custom `fabric-api`, then let `resolve_all_dependencies` add `P7dR8mSH`)
- **What:** A raw slug is stored verbatim in `MOD_IDS`; dependency ids from the API are 8-char ids. `find_existing_mod_index`/`add_mod_dependencies`/`resolve_all_dependencies` compare strings, so the same project can be appended twice (two downloads; today they collide on the sanitized title filename by luck).
- **Fix:** Normalise to `.id` from `/project/<slug>` in `get_custom_mod_display_name` (it already fetches that document).

### C30. `configure_polymc_defaults` rewrites `polymc.cfg` unconditionally on every run
- **Severity:** Low
- **Category:** robustness
- **File:** `modules/launcher_setup.sh:124-135`
- **Status:** CONFIRMED
- **What:** `cat > "$cfg_path" <<EOF` — a user's later changes (theme, language, memory) are lost on re-install/update, unlike `instance_creation`'s `handle_instance_update` which preserves options. Only `JavaPath`/`MaxMemAlloc`/`MinMemAlloc` need asserting.
- **Fix:** Write only if absent, or update keys in place (`setInstanceCfgValue`-style).

### C31. Custom-mod version switch discards the custom mod and re-prompts from scratch
- **Severity:** Low
- **Category:** logic (UX)
- **File:** `modules/mod_management.sh:1866-1916`
- **Status:** CONFIRMED
- **What:** After the pipeline re-runs, `EXTRA_REQUIRED_*` are unset and `select_user_mods` is re-entered; the mod that motivated the switch is not added — the user must answer "add custom mods? y" and paste it again. The recursion also calls `detect_java` (which may `exit 1`) and `configure_polymc_defaults` from inside a mod-selection prompt — cross-module orchestration that ARCHITECTURE §4 says belongs in `main_workflow.sh`.
- **Fix:** Return a distinct code to `main_workflow` and let it re-run the phases, carrying the pending custom mod in a global to auto-add.

### C32. CurseForge `downloadUrl: null` (distribution opt-out) reported as "no compatible file"; `/files` page size not handled
- **Severity:** Low
- **Category:** logic
- **File:** `modules/mod_management.sh:280-283`, `:343-348`, `:525-546`
- **Status:** PLAUSIBLE (API semantics: CF returns `downloadUrl: null` for opt-out projects; `/files` defaults to 50 results with pagination)
- **What:** `head -n1` on the first matching file returns the string `null`; callers then say "no compatible Fabric file for Minecraft X" — misleading, and a later file with a URL is never considered. A project with >50 files newer than its last build for the target version never shows that build (no `gameVersion=` server-side filter, no `index=` paging).
- **Fix:** `select(.downloadUrl != null)` in the filters and a distinct "author disabled third-party downloads" message; add `&gameVersion=$MC_VERSION` (and `&pageSize=50&index=`) to the files query.

### C33. `install_runtime_modules` downloads with the 15 s default timeout
- **Severity:** Low
- **Category:** robustness
- **File:** `modules/runtime_deploy.sh:181`, `:149`
- **Status:** PLAUSIBLE (depends on link speed; orchestrator/instance_lifecycle are ~100 KB each)
- **What:** `fetch_url "$base_url/$mod" "$dest"` uses `--max-time 15` (total transfer time). On a slow hotel Wi-Fi a large module can be cut off, which with C3 leaves a truncated module and aborts the install.
- **Fix:** Pass `0` (bulk artifact) or a larger named constant.

---

## Info

### C34. `accounts.json`: fixed offline UUIDs/clientTokens shared by every install; no secrets present
- **Severity:** Info
- **Category:** security (reviewed, nothing sensitive)
- **File:** `accounts.json:11,22,36,47,61,72,86,97`
- **Status:** CONFIRMED
- **What:** Four `"type": "Offline"` accounts with `"token": "0"`, constant `clientToken`s and profile ids. Nothing that grants access; the only effect is that all installs share the same four player UUIDs (irrelevant for local splitscreen; would collide only if two Decks joined the same server as "Player1"). `main_workflow.sh:122-151` validates the download. No action needed; noting for the brief's "is a secret embedded?" question: no — and the retired `token.enc` is confirmed absent from the repo (`utilities.sh:135-141`).

### C35. `fetch_url` wget branch is not equivalent to the curl branch
- **Severity:** Info
- **Category:** robustness
- **File:** `modules/utilities.sh:95-98`, `:128`
- **Status:** CONFIRMED
- **What:** wget `--timeout` is per-phase (DNS/connect/read), not total like `--max-time`; there is no analogue of the file-mode `-f` decision (wget returns 8 on HTTP error either way — fine, but partial files are left). `fetch_url_status` passes `-S` and then `2>/dev/null`, which cancels it.

### C36. `parse_custom_mod_input` trims with `xargs`
- **Severity:** Info
- **Category:** robustness
- **File:** `modules/mod_management.sh:1333`
- **Status:** CONFIRMED
- **What:** `cleaned=$(echo "$raw_input" | xargs 2>/dev/null || echo "$raw_input")` — `xargs` re-tokenises quotes/backslashes (an input with an odd `'` fails and falls back untrimmed); not a code-execution risk (no shell), but the pure-bash trim used at `:2166-2167` is the safer, already-present encoding.

### C37. Stale comment: `read_runtime_manifest` soft-guard refers to `modules/launcher_setup.sh` (T7.7)
- **Severity:** Info
- **Category:** dead-code (comment)
- **File:** `modules/runtime_deploy.sh:107-116`; `tests/test_installer.sh:184-204` now sources runtime_deploy.sh
- **Status:** CONFIRMED

### C38. `mcss_prompt` nameref could shadow its own locals
- **Severity:** Info
- **Category:** robustness
- **File:** `modules/utilities.sh:322-323`
- **Status:** CONFIRMED (no current caller passes `prompt`/`yes_default`/`eof_default` as `$4`)
- **What:** `local -n _mcss_prompt_out="$4"` after `local prompt=…` — a caller passing a variable literally named `prompt` would bind to the local, not the caller's variable. Worth a one-line guard given this is "the ONE encoding" of prompting.

### C39. Test coverage gap for the code reviewed here
- **Severity:** Info
- **Category:** test-quality
- **File:** `tests/test_installer.sh`, `tests/test_curseforge_token.sh`, `tests/test_version_stamp.sh`
- **Status:** CONFIRMED (`grep` for `match_modrinth_version|match_curseforge_version|_version_fallback_allowed|get_lwjgl_version_by_mapping|_mc_version_to_java_major|parse_custom_mod_input` in tests/: no hits)
- **What:** The #88 ladders, `_version_fallback_allowed`, the two offline tables and `parse_custom_mod_input` are pure functions (PRINCIPLES "pure functions at the edges") with zero tests; `test_version_stamp.sh` exists but did not catch C7 (no `/` in the fallback ref fixture). C11/C19/C22 would each be a fixture-JSON table test.

---

## Summary

Counts: High 2 · Medium 9 · Low 22 · Info 6 (39 findings; 34 CONFIRMED, 5 PLAUSIBLE; 1 tagged KNOWN).

Top three:
1. **C1** — `get_fabric_version` / `get_required_java_version` abort the installer on the transport failure their own fallbacks are written for (`set -e` + `pipefail` on a plain assignment; reproduced).
2. **C2** — `download_and_install_jdk` exports the highest JDK present, not the one just installed, and the post-install path skips version validation — a wrong-Java install reported as success after any version switch.
3. **C3 + C7 + C8** (the re-install/deploy path) — non-atomic launcher/module deploy deletes a working launcher on a failed fetch, the #170 ref stamp is broken for every `x/y` branch ref via unescaped `sed`, and a partial PolyMC AppImage permanently satisfies the "already present" check.

Security posture (brief's explicit questions): no `curl|bash` inside the modules (only the documented bootstrap); TLS verification is never disabled; no secret is embedded (BYOK key lives in `~/.config/...`, `token.enc` is gone); the gaps are the missing jar hash verification (C5), unbounded/argv-exposed authenticated calls (C4/C14), one predictable `/tmp` path (C13), one interpolated jq program (C15), `sed` value injection in the stamp (C7), and sourcing `~/.profile` (C6).
