title: [C13-C39] Installer mods/versions/java/deploy: low and info findings (grouped checklist)
severity: low
security: yes
type: Task
related: #88, #51, #120
---
- [ ] C13 — Predictable `/tmp/fabric_versions_$$.json` in `get_lwjgl_version`
- [ ] C14 — CurseForge key in argv at every call; key file written under default umask; `-L` forwards the header cross-host
- [ ] C15 — jq program built by string interpolation of `MC_VERSION`; unreachable jq-less fallback
- [ ] C16 — Dead `resolve_mod_dependencies` + two resolvers (a 4th/5th ladder copy); jq-less fallbacks; Modrinth id in the CF table
- [ ] C17 — `resolve_curseforge_dependencies_api` makes three calls where one suffices; first response never read
- [ ] C18 — `fetch_and_add_external_mod` CurseForge branch always "succeeds"
- [ ] C19 — Modrinth ladder ignores `version_type`, requires `primary==true`, cartesian `select` duplicates ids
- [ ] C20 — `get_fabric_version` takes `.[0]` (may be unstable); stale `0.16.9` magic fallback
- [ ] C21 — `get_lwjgl_version` reads a `.lwjgl` field Fabric meta does not publish; the static table always runs
- [ ] C22 — Offline Java table maps 1.20.5/1.20.6 to 17 (needs 21)
- [ ] C23 — Version menu lists 10 but accepts 1-20; hard-coded stale "Controlify" line
- [ ] C24 — API base URLs re-embedded x17; `$HOME/.local/share/PolyMC` x3; manifest URL twice; magic numbers
- [ ] C26 — `local x=$(mktemp)` masks failure (x6); no traps, temp files leak on Ctrl-C
- [ ] C27 — `MOD_NAME/MOD_TYPE/MOD_ID` set as globals; loop vars not `local`; `read -a` without `-r`
- [ ] C28 — Any body containing the string `"error"` treated as an API error
- [ ] C29 — Modrinth slug vs id treated as different mods (duplicate downloads)
- [ ] C30 — `polymc.cfg` rewritten unconditionally on every run
- [ ] C31 — Custom-mod version switch discards the custom mod and re-runs phases from inside a prompt
- [ ] C32 — CurseForge `downloadUrl: null` reported as "no compatible file"; `/files` paging unhandled
- [ ] C33 — Runtime modules downloaded with the 15 s default timeout
- [ ] C34 — `accounts.json`: shared offline UUIDs, no secret (info, no action)
- [ ] C35 — `fetch_url` wget branch not equivalent to curl; `-S` then `2>/dev/null` in `fetch_url_status`
- [ ] C36 — `parse_custom_mod_input` trims with `xargs`
- [ ] C37 — Stale comment references `launcher_setup.sh` in `runtime_deploy.sh`
- [ ] C38 — `mcss_prompt` nameref can shadow its own locals
- [ ] C39 — No tests for the #88 ladders, `_version_fallback_allowed`, the offline tables, `parse_custom_mod_input`

## Summary
The Low/Info tail of review C (installer: `mod_management.sh`, `version_management.sh`, `java_management.sh`, `launcher_setup.sh`, `runtime_deploy.sh`, `utilities.sh`). None of these breaks a working install on its own; together they are the hygiene debt behind the Medium/High items (C1-C11): dead ladder copies that will drift from the #88 canonical ones, argv-exposed and umask-exposed key material, unnamed magic numbers, temp files without traps, an offline Java table that is wrong for two versions, and zero tests for the pure version-match functions. C12 is folded into B25 and C25 into F18 (separate issues). The one-liners below were applied to a scratch copy: `bash -n` passes on every patched module, the combined diff passes `git apply --check` against the pristine tree, and `tests/test_installer.sh` 17/17, `tests/test_utilities.sh` 13/13, `tests/test_curseforge_token.sh` 7/7 pass with all of them applied. Items marked (security) are C13, C14, C15.

### C13. Predictable `/tmp` path in `get_lwjgl_version` (security)
`modules/version_management.sh:446` — `local temp_file="/tmp/fabric_versions_$$.json"`; `curl -o` follows a pre-planted symlink and `$$` is guessable. Every other site in these modules uses `mktemp`.
```diff
--- a/modules/version_management.sh
+++ b/modules/version_management.sh
@@ -443,10 +443,11 @@
     
     # First try to get LWJGL version from Fabric Meta API
     local fabric_game_url="${FABRIC_META_BASE}/versions/game"
-    local temp_file="/tmp/fabric_versions_$$.json"
+    local temp_file
+    temp_file=$(mktemp) || temp_file=""
     
     # Fix #51 (D14): fetch_url replaces the duplicated wget/curl branches.
-    if fetch_url "$fabric_game_url" "$temp_file" 2>/dev/null; then
+    if [[ -n "$temp_file" ]] && fetch_url "$fabric_game_url" "$temp_file" 2>/dev/null; then
         if command -v jq >/dev/null 2>&1 && [[ -s "$temp_file" ]]; then
             # Try to find LWJGL version for our Minecraft version
             LWJGL_VERSION=$(jq -r --arg mc_ver "$MC_VERSION" '
```

### C14. CurseForge key in argv; key file briefly world-readable; `-L` forwards headers (security)
`modules/mod_management.sh:476,828,976,993,1014,1135,1232,1455,1547,1676`, `modules/version_management.sh:254`, `modules/utilities.sh:198-200`. `-H "x-api-key: $key"` puts the secret in `/proc/<pid>/cmdline` for every request; `printf > "$CURSEFORGE_KEY_FILE"` runs under the default umask before the `chmod 600`; curl `-L` forwards custom headers to a different host on redirect. The argv part is fixed by C4's `mcss_cf_header_file` + `fetch_url … "$hdr"` as sites convert; drop `-L` for API calls at that time. The umask part:
```diff
--- a/modules/utilities.sh
+++ b/modules/utilities.sh
@@ -196,7 +196,7 @@
         key=$(printf '%s' "$key" | tr -d '[:space:]')
         if [[ -n "$key" ]]; then
             if mkdir -p "$(dirname "$CURSEFORGE_KEY_FILE")" 2>/dev/null \
-                && printf '%s\n' "$key" > "$CURSEFORGE_KEY_FILE" 2>/dev/null; then
+                && (umask 077; printf '%s\n' "$key" > "$CURSEFORGE_KEY_FILE") 2>/dev/null; then
                 chmod 600 "$CURSEFORGE_KEY_FILE" 2>/dev/null || true
                 print_info "Saved CurseForge key to $CURSEFORGE_KEY_FILE (chmod 600) — delete it to be re-prompted."
             fi
```

### C15. jq program built by string interpolation of `MC_VERSION` (security pattern)
`modules/mod_management.sh:916-923` — the only site not using `--arg`; a `"` in `MC_VERSION` would change the program (not exploitable today: the value comes from the Mojang manifest or a numeric menu index). The grep-based "no jq" branch right below (`:924-931`) is unreachable (`:903` already ran `jq -e .`; preflight hard-requires jq) — delete it.
```diff
--- a/modules/mod_management.sh
+++ b/modules/mod_management.sh
@@ -913,14 +913,14 @@
         
         # Simple jq filter to get dependencies from compatible fabric versions with strict matching
         # Use temporary file to avoid command line length limits
-        dependencies=$(jq -r "
-            .[] 
-            | select(.loaders[]? == \"fabric\") 
-            | select(.game_versions[]? | (. == \"$MC_VERSION\" or . == \"$mc_major_minor\" or . == \"${mc_major_minor}.x\" or . == \"${mc_major_minor}.0\"))
-            | .dependencies[]? 
-            | select(.dependency_type == \"required\") 
+        dependencies=$(jq -r --arg v "$MC_VERSION" --arg mm "$mc_major_minor" '
+            .[]
+            | select(.loaders[]? == "fabric")
+            | select(.game_versions[]? | (. == $v or . == $mm or . == ($mm + ".x") or . == ($mm + ".0")))
+            | .dependencies[]?
+            | select(.dependency_type == "required")
             | .project_id
-        " < "$tmp_file" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
+        ' < "$tmp_file" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
     else
         # Fallback to basic grep parsing if jq is not available
         local deps_section=$(grep -o '"dependencies":\[[^]]*\]' "$tmp_file" | head -1)
```

### C16. Dead `resolve_mod_dependencies` + `resolve_modrinth_dependencies` + `resolve_curseforge_dependencies`
`modules/mod_management.sh:688-864` — ~185 lines with no callers outside the dispatcher's own two calls (`grep -rn` across repo; the live path is `resolve_modrinth_dependencies_api` at `:599`), including another exact→major.minor→.x Modrinth ladder and an unguarded CF combined query that will drift from `match_*_version`. Same file: jq-less `grep` fallbacks at `:1090-1094` (unreachable) and a `"DOUdJVEm"` (Controlify, a MODRINTH id) entry in the CurseForge fallback-name table at `:1159-1162`. Fix: delete the three functions and their header lines, the jq-less branches, and the `DOUdJVEm` case; `:828` also disappears from the C4 site list.

### C17. `resolve_curseforge_dependencies_api` makes three API calls where one suffices
`modules/mod_management.sh:970-1031` — fetches `/mods/<id>` into `temp_file` but only tests `-s`; then `/files`, picks a file id, then `/files/<fid>` for `.data.dependencies`. The `/files` response already carries `dependencies[]` per file (the sibling at `:851-856` reads it there). Also a hard-coded `"238222") dependencies="306612"` (JEI→Fabric API, "legacy 1.21.1 era") that never applies to a Fabric splitscreen install. Fix: one `/files?modLoaderType=4&gameVersion=$MC_VERSION` call (through `fetch_url` per C4) and read `.dependencies` from the matched file; drop the `/mods/<id>` fetch and the JEI case.

### C18. `fetch_and_add_external_mod` CurseForge branch always "succeeds"
`modules/mod_management.sh:1156-1188` — header says "return 1 if nothing could be added", but the CF branch unconditionally appends `"External Dependency (CF:$id)"` with `MOD_URLS+=("$download_url")` (possibly empty) and sets `success=true`, even with no API key (`:1126` false); `resolve_all_dependencies:656-657` then logs "Successfully added external dependency" for a placeholder reported missing at download time. Fix: append only when `download_url` (or at least `mod_title`) resolved; otherwise `return 1`.

### C19. Modrinth ladder ignores `version_type`, requires `primary == true`, duplicates dependency ids
`modules/mod_management.sh:190-193`, `:1612` — `.files[] | select(.primary == true) | .url | head -n1`: Modrinth returns newest-first, so an alpha/beta build for the target beats an older release (no `select(.version_type=="release")` preference); a version whose files carry no `primary` flag is "no match" although the API docs say to take the first file then (`instance_creation.sh:419` already uses `(.files | map(select(.primary)) | .[0].url) // (.files[0].url)` — a divergence H13 fixed on one side only). The `select(.game_versions[] == $v and (.loaders[] == "fabric"))` cartesian form emits a version once per true pair, so `dep_ids` can contain duplicates (harmless today; `add_mod_dependencies` de-dups by index). Fix: prefer `release` then fall back to any; use the `// (.files[0].url)` form in `_modrinth_tier_match`; `any(.game_versions[]; . == $v)`.

### C20. `get_fabric_version` takes `.[0]` and pins a stale fallback
`modules/version_management.sh:404-410` — `.[0].version` with no `select(.stable)` (PLAUSIBLE: verify with `curl -s https://meta.fabricmc.net/v2/versions/loader | jq '.[0]'`); the `0.16.9` fallback is a magic literal that ages (and was unreachable — C1). Name the fallback at the installer constants block (`MCSS_FABRIC_LOADER_FALLBACK`).
```diff
--- a/modules/version_management.sh
+++ b/modules/version_management.sh
@@ -402,7 +402,7 @@
     # Query Fabric Meta API for the latest loader version
     # Fix #51 (D14): fetch_url replaces the bare curl call.
     FABRIC_VERSION=$(fetch_url "${FABRIC_META_BASE}/versions/loader" - \
-        | jq -r '.[0].version' 2>/dev/null)
+        | jq -r '[.[] | select(.stable)][0].version // .[0].version' 2>/dev/null)
     
     # Fallback to known stable version if API call fails
     if [[ -z "$FABRIC_VERSION" || "$FABRIC_VERSION" == "null" ]]; then
```
(Combine with C1's `|| FABRIC_VERSION=""` on the same line.)

### C21. `get_lwjgl_version` reads a `.lwjgl` field Fabric meta does not publish
`modules/version_management.sh:445-455`, `:482-505` — `/v2/versions/game` is documented as `[{version, stable}]` (PLAUSIBLE: confirm with `curl -s https://meta.fabricmc.net/v2/versions/game | jq '.[0]'`), so the API branch is a wasted round-trip and the hand-maintained table (`3.4.1` for 26.x, default `3.3.3`) is what is baked into `mmc-pack.json` (`instance_creation.sh:86-96`). Fix: derive LWJGL from the Mojang version JSON already fetched in `get_required_java_version` (`.libraries[].name | select(startswith("org.lwjgl:lwjgl:")) | split(":")[2]`), keep the table as offline fallback only.

### C22. Offline Java table wrong for MC 1.20.5 / 1.20.6
`modules/java_management.sh:85-86` — `^1\.(1[8-9]|20)(\.|$)` → 17, but Mojang raised the requirement to Java 21 at 1.20.5. Only matters when the manifest is unreachable (reachable once C1 lands).
```diff
--- a/modules/java_management.sh
+++ b/modules/java_management.sh
@@ -80,10 +80,11 @@
         # installs jdk-25 via the manifest path). Same scheme test as
         # version_management.sh:get_lwjgl_version_by_mapping (#91).
         echo "25"
-    elif [[ "$mc_version" =~ ^1\.2[1-9](\.|$) ]]; then
-        echo "21"  # 1.21+ requires Java 21
+    elif [[ "$mc_version" =~ ^1\.2[1-9](\.|$) ]] \
+        || [[ "$mc_version" =~ ^1\.20\.([5-9]|[1-9][0-9])$ ]]; then
+        echo "21"  # 1.21+ and 1.20.5/1.20.6 require Java 21
     elif [[ "$mc_version" =~ ^1\.(1[8-9]|20)(\.|$) ]]; then
-        echo "17"  # 1.18-1.20 requires Java 17
+        echo "17"  # 1.18-1.20.4 requires Java 17
     elif [[ "$mc_version" =~ ^1\.17(\.|$) ]]; then
         echo "16"  # 1.17 requires Java 16
     else
```
(Verified on the scratch copy: 1.20.4→17, 1.20.5→21, 1.20.6→21, 1.21→21, 1.20→17.)

### C23. Version menu lists 10 but accepts 1-20; hard-coded stale "Controlify" line
`modules/version_management.sh:347-353`, `:355-356`, `:364`, `:380` — the loop prints `counter -le 10`, the prompt says `1-${#supported_versions[@]}` (up to 20) and the validator accepts up to 20, so "14" silently selects an unlisted version. `:355-356` prints a fixed "✅ Controlify (controller support)" although `mods.conf` has seven required mods and `_required_mods_summary` (`mod_management.sh:1938`) exists for exactly this. Fix: `local shown=$(( ${#supported_versions[@]} < 10 ? ${#supported_versions[@]} : 10 ))` and use `$shown` in the prompt and the `-le` check; replace the two `echo` lines with `echo "  ✅ $(_required_mods_summary)"`.

### C24. Consumer-side literal re-embeds and unnamed magic numbers
`modules/mod_management.sh` (`https://api.modrinth.com/v2` x7, `https://api.curseforge.com/v1` x10), `modules/version_management.sh:189` (bare, inconsistent), `modules/java_management.sh:176,287,399` (`${TARGET_DIR:-$HOME/.local/share/PolyMC}`), `:177` (`arch="x64"`), `version_management.sh:98` (20), `mod_management.sh:1512,1557` (30), `:476` (15), `:1455` (12), `:1547` (15), `launcher_setup.sh:127` (`ConfigVersion=1.2`), the Mojang manifest URL typed at `java_management.sh:111` and `version_management.sh:85`. The installer entry already exports `MODRINTH_API_BASE`/`CURSEFORGE_API_BASE`/`TARGET_DIR` (`install-minecraft-splitscreen.sh:120-122`); the `:-` copies can drift (ARCHITECTURE §3's exact 1280/800 pattern). Fix: bare `$MODRINTH_API_BASE` etc. in consumers; `MCSS_MOJANG_MANIFEST_URL`, `MCSS_VERSION_SCAN_DEPTH=20`, `MCSS_API_TIMEOUT_S` (C4 adds it) at the constants block.

### C26. `local x=$(mktemp)` masks failure; no traps
`modules/mod_management.sh:973,990,1011,1069,1132,1229` (SC2155: `temp_file=""` → `curl -o ""`), and no `trap` on any `mktemp` in mod_management/version_management, so Ctrl-C during any of the ~20 API calls leaks the file. Fix: `local f; f=$(mktemp) || return 1` at each site; one module-level `_MCSS_TMPDIR=$(mktemp -d)` removed by the installer entry's existing `cleanup` trap, with `mktemp -p "$_MCSS_TMPDIR"` everywhere.

### C27. Function-scope leaks
`modules/mod_management.sh:123` (`IFS='|' read -r MOD_NAME MOD_TYPE MOD_ID` creates upper-case globals one letter from the `MOD_TYPES`/`MOD_IDS` arrays), `:609-627` (`dep_platform`, `dep_id`, `i` not `local`), `:2164-2170` (`deps`, `j`), `:2202` (`read -a dep_arr` — no `-r`, not local). Fix: `local mod_name mod_type mod_id`, `local dep_platform dep_id i deps j`, `local -a dep_arr; read -r -a dep_arr`.

### C28. Any body containing `"error"` treated as an API error
`modules/mod_management.sh:1082` — `grep -q '"error"'` on the whole project JSON: a description containing the quoted word skips a legitimate dependency.
```diff
--- a/modules/mod_management.sh
+++ b/modules/mod_management.sh
@@ -1079,7 +1079,7 @@
             
             if [[ "$download_success" == true && -s "$temp_file" ]]; then
                 # Check if the file contains valid JSON (not an error)
-                if ! grep -q '"error"' "$temp_file" 2>/dev/null; then
+                if ! jq -e '.error? // empty' "$temp_file" >/dev/null 2>&1; then
                     # Extract mod name from JSON file using jq if available, fallback to grep
                     local mod_title=""
                     local mod_description=""
```

### C29. Modrinth slugs and ids treated as different mods (PLAUSIBLE)
`modules/mod_management.sh:1372-1376`, `:1391-1403`, `:631-632` — a raw slug (`fabric-api`) is stored verbatim in `MOD_IDS`; dependency ids from the API are 8-char ids (`P7dR8mSH`); `find_existing_mod_index`/`add_mod_dependencies`/`resolve_all_dependencies` compare strings, so the same project can be appended twice (two downloads that collide on the sanitized title filename by luck). Fix: normalise to `.id` from `/project/<slug>` in `get_custom_mod_display_name` (it already fetches that document). Verify with a live run: add custom `fabric-api`, then let `resolve_all_dependencies` add `P7dR8mSH`.

### C30. `configure_polymc_defaults` rewrites `polymc.cfg` unconditionally
`modules/launcher_setup.sh:124-135` — `cat > "$cfg_path" <<EOF` on every run loses a user's later PolyMC changes (theme, language, memory), unlike `handle_instance_update`, which preserves options. Only `JavaPath`/`MaxMemAlloc`/`MinMemAlloc` need asserting. Fix: write the heredoc only if the file is absent; otherwise update those three keys in place (`sed -i "s|^JavaPath=.*|JavaPath=${java_cfg_path}|"` etc., appending if missing).

### C31. Custom-mod version switch discards the custom mod and re-runs phases from inside a prompt
`modules/mod_management.sh:1866-1916` — after the pipeline re-runs, `EXTRA_REQUIRED_*` are unset and `select_user_mods` is re-entered; the mod that motivated the switch is not added (the user must paste it again). The recursion also calls `detect_java` (which may `exit 1`) and `configure_polymc_defaults` from inside a mod-selection prompt — cross-module orchestration ARCHITECTURE §4 assigns to `main_workflow.sh`. Fix: return a distinct code (e.g. 3) to `main_workflow`, let it re-run the version/java/fabric/lwjgl phases, and carry the pending custom mod in a `MCSS_PENDING_CUSTOM_MOD="platform|id"` global that `select_user_mods` auto-adds.

### C32. CurseForge `downloadUrl: null` reported as "no compatible file"; `/files` paging unhandled (PLAUSIBLE)
`modules/mod_management.sh:280-283`, `:343-348`, `:525-546` — CF returns `downloadUrl: null` for projects that opted out of third-party distribution; `head -n1` on the first matching file yields the string `null`, callers say "no compatible Fabric file for Minecraft X" (misleading) and a later file with a URL is never considered. `/files` defaults to 50 results, so a project with >50 newer files never shows its build for the target version. Fix: `select(.downloadUrl != null)` in `_curseforge_tier_url` and the combined filter, a distinct "author disabled third-party downloads" message, and `&gameVersion=$MC_VERSION` (plus `&pageSize=50&index=` if needed) on the files query.

### C33. Runtime modules downloaded with the 15 s default timeout (PLAUSIBLE on slow links)
`modules/runtime_deploy.sh:181` (and the manifest at `:149`) — `--max-time 15` is total transfer time; `orchestrator.sh`/`instance_lifecycle.sh` are ~100 KB each, which a slow hotel Wi-Fi can cut off (with C3 unfixed, leaving a truncated module).
```diff
--- a/modules/runtime_deploy.sh
+++ b/modules/runtime_deploy.sh
@@ -178,7 +178,7 @@
         # 3. Download from GitHub
         # Fix #51 (D14): fetch_url replaces the curl/wget/neither
         # branches (its no-downloader case also lands here as a failure).
-        elif ! fetch_url "$base_url/$mod" "$dest" 2>/dev/null; then
+        elif ! fetch_url "$base_url/$mod" "$dest" 0 2>/dev/null; then
             print_error "Failed to download runtime module: $mod"
             (( failed++ )) || true
             continue
```
(Apply after C3, whose diff moves this line's target to the staging dir; the `0` is unchanged there.)

### C34. `accounts.json`: shared offline UUIDs, no secret (info)
`accounts.json:11,22,36,47,61,72,86,97` — four `"type": "Offline"` accounts with `"token": "0"`, constant `clientToken`s and profile ids. Nothing grants access; the only effect is that every install shares the same four player UUIDs (irrelevant for local splitscreen; collides only if two Decks join the same server as "Player1"). `main_workflow.sh:122-151` validates the download; the retired `token.enc` is confirmed absent (`utilities.sh:135-141`). No action.

### C35. `fetch_url` wget branch not equivalent to curl (info)
`modules/utilities.sh:95-98`, `:128` — wget `--timeout` is per phase (DNS/connect/read), not total like `--max-time`; there is no analogue of the file-mode `-f` decision (wget returns 8 on HTTP error either way, leaving partial files); `fetch_url_status` passes `-S` and then `2>/dev/null`, which cancels it. Note in the header that wget is a degraded fallback (SteamOS ships curl), and drop the dead `-S`.

### C36. `parse_custom_mod_input` trims with `xargs`
`modules/mod_management.sh:1333` — `xargs` re-tokenises quotes/backslashes (an odd `'` makes it fail and fall back untrimmed); not a code-execution risk, but the pure-bash trim at `:2166-2167` is the safer, already-present encoding.
```diff
--- a/modules/mod_management.sh
+++ b/modules/mod_management.sh
@@ -1330,7 +1330,8 @@
 
     # Trim leading/trailing whitespace
     local cleaned
-    cleaned=$(echo "$raw_input" | xargs 2>/dev/null || echo "$raw_input")
+    cleaned="${raw_input#"${raw_input%%[![:space:]]*}"}"
+    cleaned="${cleaned%"${cleaned##*[![:space:]]}"}"
     if [[ -z "$cleaned" ]]; then
         return 1
     fi
```

### C37. Stale comment references `launcher_setup.sh` (info)
`modules/runtime_deploy.sh:112` — the soft-guard comment says T7.7 does `source modules/launcher_setup.sh`; `tests/test_installer.sh:203` sources `runtime_deploy.sh`.
```diff
--- a/modules/runtime_deploy.sh
+++ b/modules/runtime_deploy.sh
@@ -109,7 +109,7 @@
 # that entry script (same process), so the function is already defined by
 # the time install_runtime_modules() runs below — redefine it here ONLY if
 # absent (cross-module soft guard, STYLE-GUIDE §7.6) so
-# tests/test_installer.sh's standalone `source modules/launcher_setup.sh`
+# tests/test_installer.sh's standalone `source modules/runtime_deploy.sh`
 # (T7.7) keeps passing without depending on the installer entry at all.
 declare -f read_runtime_manifest >/dev/null 2>&1 || read_runtime_manifest() {
     grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null
```

### C38. `mcss_prompt` nameref could shadow its own locals (info)
`modules/utilities.sh:322-323` — `local -n _mcss_prompt_out="$4"` after `local prompt=…`: a caller passing a variable literally named `prompt`, `yes_default` or `eof_default` would bind to the local, not the caller's variable (no current caller does). One guard keeps "the ONE encoding of prompting" honest:
```diff
--- a/modules/utilities.sh
+++ b/modules/utilities.sh
@@ -320,6 +320,8 @@
 #   side effect — sets the named variable; logs which path was taken
 mcss_prompt() {
     local prompt="$1" yes_default="$2" eof_default="$3"
+    case "$4" in prompt|yes_default|eof_default|_mcss_prompt_out)
+        print_error "mcss_prompt: outvar '$4' shadows an internal name"; return 1;; esac
     local -n _mcss_prompt_out="$4"
     if [[ "${ASSUME_YES:-false}" == "true" ]]; then
         print_info "--yes: skipping prompt, using default."
```

### C39. Test coverage gap (info)
`grep -rn 'match_modrinth_version\|match_curseforge_version\|_version_fallback_allowed\|get_lwjgl_version_by_mapping\|_mc_version_to_java_major\|parse_custom_mod_input' tests/` → no hits. These are pure functions (PRINCIPLES "pure functions at the edges"); `test_version_stamp.sh` existed but did not catch C7 (no `/` in its ref fixture). Fix: a fixture-JSON table test (`tests/test_version_match.sh`): for each `(fixture, target, check_standalone/allow_fallback) → expected url-or-empty` row call the two ladders; a table test for `_mc_version_to_java_major` (pins C22) and `get_lwjgl_version_by_mapping`; a table test for `parse_custom_mod_input` (URLs, slugs, numeric ids, whitespace, junk); plus the C7 tests (T1.7-T1.9) and the C11 agreement test (T7.25), each mutation-tested per PRINCIPLES #4.

## Hardware verification
CI + unit tests for everything in this group: none of it touches the runtime launch path. After the batch lands, one `tests/hardware/run_all.sh stage0b` (full installer verification) on the Deck in Desktop mode, once with a custom CurseForge mod added (exercises C14/C17/C18/C32 paths) and once with a custom Modrinth slug (C29), followed by a stage1 smoke and a single 4-up launch (stage2) to confirm nothing in the installer batch changed what the instances load (`grep -c 'Loading .* mods' ~/.local/share/PolyMC/instances/*/logs/latest.log` unchanged from before the batch).

## References
Review C13-C39 (docs/reviews/2026-09-28/C-installer-mods.md, "Low" and "Info"; consolidated §5.3 and §7 cross-cutting patterns 3-5). C12 → B25, C25 → F18 (folded elsewhere). PRINCIPLES #4 (mutation-test — C39), #6 (bounded waits — C33), #9 (one encoding — C16, C19, C24, C36). STYLE-GUIDE §7.4 (function scope — C27), §7.9 (temp files — C26). Related: #88 (canonical ladders — C16, C19, C39), #51 (D14 transport — C33, C35), #120 (BYOK key file — C14), #185 (`mcss_prompt` — C38), #170/#89 (C7 test gap — C39).
