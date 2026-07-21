#!/bin/bash
# =============================================================================
# MOD MANAGEMENT MODULE
# =============================================================================
# Mod compatibility checking, dependency resolution, and interactive user
# selection, across both Modrinth and CurseForge. Owns the canonical
# version-match policy (Fix #88 — see the divider comment below) that
# version_management.sh's check_mod_version_compatibility also consumes.
#
# Public API — Modrinth/CurseForge version-match policy (Fix #88, shared):
#   match_modrinth_version(json, target_ver, [check_standalone])
#                                       — stdout: "<url>\t<dep_ids>", exit
#                                         0/1 on match/no-match
#   match_curseforge_version(json, target_ver, allow_fallback)
#                                       — stdout: "<url>\t<dep_ids>", exit
#                                         0/1 on match/no-match
#
# Public API — mod compatibility checking:
#   check_mod_compatibility()          — iterates MODS[], no stdout contract
#   check_modrinth_mod(name, id)       — exit 0/1; appends to SUPPORTED_MODS
#                                         etc. on match
#   check_curseforge_mod(name, id)     — exit 0/1; appends to SUPPORTED_MODS
#                                         etc. on match
#   check_modrinth_mod_strict(name, id) / check_curseforge_mod_strict(name,
#     id)                              — exact-MC_VERSION-only variant for
#                                         custom mods; same append behavior
#
# Public API — dependency resolution:
#   resolve_all_dependencies()         — mutates FINAL_MOD_INDEXES; no
#                                         stdout contract
#   resolve_mod_dependencies(mod_id)   — stdout: space-separated dep IDs
#   resolve_modrinth_dependencies(id, name) / resolve_curseforge_dependencies
#     (id, name)                       — stdout: space-separated dep IDs
#   resolve_modrinth_dependencies_api(id) / resolve_curseforge_dependencies_
#     api(id)                          — stdout: space-separated dep IDs
#     (always prints something, even "", for command-substitution capture)
#   fetch_and_add_external_mod(id, type)
#                                       — exit 0/1; appends to SUPPORTED_MODS
#                                         etc. and FINAL_MOD_INDEXES
#   get_curseforge_download_url(id)    — stdout: download URL or empty
#   resolve_conf_dependencies()        — BFS over MOD_DEPS_BY_NAME; mutates
#                                         FINAL_MOD_INDEXES
#   add_mod_dependencies(idx, added_map_nameref)
#                                       — mutates FINAL_MOD_INDEXES/added_map
#
# Public API — custom mod input / user selection:
#   parse_custom_mod_input(raw, platform_nameref, id_nameref)
#                                       — exit 0/1; fills namerefs on success
#   find_existing_mod_index(platform, id)
#                                       — stdout: index, or exit 1 if absent
#   get_custom_mod_display_name(platform, id)
#                                       — stdout: best-effort display name
#   print_supported_versions_for_custom_mod(platform, id)
#                                       — stdout: "  - <version>" lines
#   prompt_custom_mods(added_map_nameref)
#                                       — interactive; return 2 signals
#                                         "MC version changed, restart
#                                         selection" to select_user_mods
#   select_user_mods()                 — interactive; drives the full mod
#                                         selection + dependency pipeline
#
# (get_supported_minecraft_versions is Public API of version_management.sh,
# not this module, despite being closely related — not listed here.)
#
# Globals CONSUMED (set elsewhere, read here):
#   MC_VERSION                          — target MC version (installer
#                                          globals)
#   MODS[]                              — "Name|platform|id" list, from
#                                          mods.conf (installer globals)
#   REQUIRED_SPLITSCREEN_MODS[]          — from mods.conf (installer globals)
#   MOD_DEPS_BY_NAME{}                   — declared mod deps, from mods.conf
#   MODRINTH_API_BASE, CURSEFORGE_API_BASE — API base URLs (installer)
#   CurseForge API token — via utilities.sh:get_curseforge_api_token
#
# Globals PROVIDED (set/appended here, read elsewhere):
#   SUPPORTED_MODS, MOD_DESCRIPTIONS, MOD_URLS, MOD_IDS, MOD_TYPES,
#     MOD_DEPENDENCIES[]                — parallel arrays; appended to by
#                                          every check_*/fetch_and_add_*
#                                          function on a compatible match
#   FINAL_MOD_INDEXES[]                 — indexes into the arrays above
#                                          selected for install; appended to
#                                          throughout dependency resolution
#                                          and user selection
#   EXTRA_REQUIRED_MOD_ID/PLATFORM/NAME  — set by prompt_custom_mods when the
#                                          user asks to switch MC version to
#                                          support a custom mod; consumed by
#                                          version_management.sh
#   CUSTOM_MOD_LAST_INCOMPAT_REASON      — set by check_modrinth_mod_strict/
#                                          check_curseforge_mod_strict; read
#                                          by prompt_custom_mods (intra-
#                                          module handoff, both sides here)
#
# Inputs:  Modrinth API (api.modrinth.com), CurseForge API, network access
#          via utilities.sh:fetch_url/fetch_url_status
# Outputs: print_* progress/status to stdout/stderr; downloaded mod jars are
#          NOT written here (only URLs are resolved — instance_creation.sh
#          does the actual download); machine data to stdout where the
#          Public API list above says so
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.3 2026-07-17  #47/#88: one token fetch, one version-match policy
#   v1.2 2026-07-15  #51 D14: fetch_url/fetch_url_status transport adopted
#   v1.1 2026-06-23  Splitscreen Support mod removed; KWin does tiling
#   v1.0 2026-06-14  mods.conf externalized; Controlify + BFS dep resolver
#   v0.2 2026-04-26  Custom mod flow with guided version switching
#   v0.1 2025-06-27  Initial extraction from monolith
# =============================================================================

# check_mod_compatibility: Main coordination function for mod compatibility
# checking. Iterates MODS[] and delegates to the platform-specific checker.
# Inputs:
#   Globals: MC_VERSION, MODS[] (read)
# Outputs:
#   side effect — appends to SUPPORTED_MODS/MOD_* on each compatible mod
#   stdout — print_* progress/summary only, not a data contract
check_mod_compatibility() {
    print_header "🔍 CHECKING MOD COMPATIBILITY"
    print_progress "Checking mod compatibility for Minecraft $MC_VERSION..."
    
    # Process each mod in the MODS array
    # Format: "ModName|platform|mod_id" 
    for mod in "${MODS[@]}"; do
        IFS='|' read -r MOD_NAME MOD_TYPE MOD_ID <<< "$mod"
        
        # Route to appropriate platform-specific checker
        # Use || true to prevent set -e from exiting on mod check failures
        if [[ "$MOD_TYPE" == "modrinth" ]]; then
            check_modrinth_mod "$MOD_NAME" "$MOD_ID" || true
        elif [[ "$MOD_TYPE" == "curseforge" ]]; then
            check_curseforge_mod "$MOD_NAME" "$MOD_ID" || true
        fi
    done
    
    print_success "Mod compatibility check completed"
    local supported_count=0
    if [[ ${#SUPPORTED_MODS[@]} -gt 0 ]]; then
        supported_count=${#SUPPORTED_MODS[@]}
    fi
    print_info "Found $supported_count compatible mods for Minecraft $MC_VERSION"
}

# =============================================================================
# Fix #88: shared version-match policy. Four sites (check_modrinth_mod,
# check_curseforge_mod, get_curseforge_download_url here, plus
# version_management.sh's check_mod_version_compatibility) each
# reimplemented an "exact -> coarser fallback" ladder. The pieces below are
# the parts genuinely identical across sites; get_curseforge_download_url
# keeps its own tier LIST (it has a previous-patch tier the others don't,
# and lacks the .0 tier the others have — a real divergence, preserved,
# not unified — see its own comment).
# =============================================================================

# _version_fallback_allowed: Shared safety guard for the fallback tiers
# (major.minor / .x / .0 / previous-patch). Blocks falling back to a
# coarser match when either a release exists at the bare major.minor
# (misleading to also accept a wildcard) or the requested patch is HIGHER
# than any published patch in the series (nothing coarser can be "close
# enough"). All #88 duplicate ladders computed this identically; callers
# that never computed the standalone check (a pre-existing, preserved
# divergence — see match_modrinth_version) pass "" for $2.
# Inputs:
#   $1 — mc_patch_version (may be empty for a non-patch/yearly version)
#   $2 — has_standalone_major_minor (jq output, or "" if not checked)
#   $3 — highest_patch (numeric jq output, or "" if none published)
# Outputs:
#   return — 0 = fallback allowed, 1 = blocked
_version_fallback_allowed() {
    local patch="$1" standalone="$2" highest="$3"
    if [[ -n "$standalone" && "$standalone" != "null" ]]; then
        return 1
    fi
    if [[ -n "$highest" && "$highest" != "null" && -n "$patch" \
        && "$patch" -gt "$highest" ]]; then
        return 1
    fi
    return 0
}

# _modrinth_tier_match: One Modrinth version-match attempt for a SINGLE
# game-version string (exact, or a caller-supplied coarser tier).
# Inputs:
#   $1 — version_json (Modrinth /project/<id>/version response body)
#   $2 — game version string to match exactly, fabric loader required
# Outputs:
#   stdout — "<url>\t<space-separated required dependency project_ids>",
#            empty when no primary Fabric file matches this tier
_modrinth_tier_match() {
    local version_json="$1" v="$2"
    local url deps
    url=$(printf "%s" "$version_json" | jq -r --arg v "$v" \
        '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric"))
         | .files[] | select(.primary == true) | .url' \
        2>/dev/null | head -n1)
    [[ -z "$url" || "$url" == "null" ]] && return 0
    deps=$(printf "%s" "$version_json" | jq -r --arg v "$v" \
        '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric"))
         | .dependencies[]? | select(.dependency_type=="required")
         | .project_id' 2>/dev/null | tr '\n' ' ')
    printf '%s\t%s\n' "$url" "$deps"
}

# match_modrinth_version: Fix #88 canonical Modrinth version-match policy
# (mod_management.sh owns it — ARCHITECTURE.md §2). Ladder: exact
# target_version, then — if _version_fallback_allowed permits —
# major.minor, major.minor.x, major.minor.0.
# Inputs:
#   $1 — version_json
#   $2 — target_version (the MC version to match, e.g. "1.21.6")
#   $3 — check_standalone ("1"/"0", default "1"). check_modrinth_mod's
#        original guard blocked fallback when a standalone major.minor
#        release existed; version_management.sh's check_mod_version_compat
#        -ibility computed that same value but never actually used it
#        (dead variable in the pre-dedup copy) — a genuine, pre-existing
#        behavioral divergence. Passing "0" here reproduces that weaker
#        guard exactly rather than silently tightening it as part of this
#        cleanup; a separate issue may want to fix the underlying bug.
# Outputs:
#   stdout — "<url>\t<space-separated required dependency project_ids>"
#            on match, empty on no match
#   return — 0 on match, 1 on no match
match_modrinth_version() {
    local version_json="$1" target_version="$2" check_standalone="${3:-1}"
    local match
    match=$(_modrinth_tier_match "$version_json" "$target_version")
    if [[ -n "$match" ]]; then
        printf '%s\n' "$match"
        return 0
    fi

    local mc_major_minor
    mc_major_minor=$(echo "$target_version" | grep -oE '^[0-9]+\.[0-9]+')
    [[ -z "$mc_major_minor" ]] && return 1

    local mc_patch_version
    mc_patch_version=$(echo "$target_version" \
        | grep -oE '^[0-9]+\.[0-9]+\.([0-9]+)' | grep -oE '[0-9]+$')

    local standalone="" highest=""
    if [[ -n "$mc_patch_version" ]]; then
        if [[ "$check_standalone" == "1" ]]; then
            standalone=$(printf "%s" "$version_json" | jq -r \
                --arg mm "$mc_major_minor" '
                .[] | select((.loaders[]? == "fabric")
                    and any(.game_versions[]?; . == $mm))
                | .version_number' 2>/dev/null | head -n1)
        fi
        highest=$(printf "%s" "$version_json" | jq -r \
            --arg mm "$mc_major_minor" '
            [.[] | select(.loaders[]? == "fabric") | .game_versions[]?
             | select(startswith($mm + ".") and (split(".")|length==3))
             | (split(".")[2] | tonumber?)]
            | map(select(. != null))
            | if length > 0 then max else empty end' 2>/dev/null)
    fi

    _version_fallback_allowed "$mc_patch_version" "$standalone" \
        "$highest" || return 1

    local tier
    for tier in "$mc_major_minor" "$mc_major_minor.x" "$mc_major_minor.0"; do
        match=$(_modrinth_tier_match "$version_json" "$tier")
        if [[ -n "$match" ]]; then
            printf '%s\n' "$match"
            return 0
        fi
    done
    return 1
}

# _curseforge_tier_url: One CurseForge version-match attempt for a SINGLE
# gameVersions string. No loader filter — the caller's API query already
# scoped to modLoaderType=4.
# Inputs:
#   $1 — version_json (CurseForge /mods/<id>/files response body)
#   $2 — game version string to match exactly
# Outputs:
#   stdout — matched downloadUrl, empty if none
_curseforge_tier_url() {
    local version_json="$1" v="$2"
    printf "%s" "$version_json" | jq -r --arg v "$v" \
        '.data[]? | select(.gameVersions[]? == $v) | .downloadUrl' \
        2>/dev/null | head -n1
}

# match_curseforge_version: Fix #88 canonical CurseForge version-match
# policy for the sites that use the combined "exact OR guarded-fallback"
# query style (mod_management.sh's check_curseforge_mod and
# version_management.sh's check_mod_version_compatibility). NOTE this does
# NOT strictly prefer an exact match over a fallback match when a fallback
# release happens to sort earlier in the API's .data[] array — that is the
# PRE-EXISTING behavior of both sites this consolidates, kept as-is rather
# than "fixed" (#88's no-behavior-change mandate). get_curseforge_download
# _url uses a different, sequential-tier style (see its own comment) and
# is NOT routed through this — its ladder genuinely differs (previous-
# patch tier, no .0 tier).
# Inputs:
#   $1 — version_json
#   $2 — target_version (the MC version to match, e.g. "1.21.6")
#   $3 — allow_fallback ("1"/"0"). check_curseforge_mod computes this from
#        _version_fallback_allowed; check_mod_version_compatibility's
#        original CurseForge branch never gated the fallback at all
#        (another pre-existing divergence) — its call site always passes
#        "1" to reproduce that unconditional behavior exactly.
# Outputs:
#   stdout — "<url>\t<space-separated required dependency modIds>" on
#            match (base64-decoded), empty on no match
#   return — 0 on match, 1 on no match
match_curseforge_version() {
    local version_json="$1" target_version="$2" allow_fallback="$3"
    local mc_major_minor mc_major_minor_x mc_major_minor_0
    mc_major_minor=$(echo "$target_version" | grep -oE '^[0-9]+\.[0-9]+')
    mc_major_minor_x="$mc_major_minor.x"
    mc_major_minor_0="$mc_major_minor.0"
    local af="false"
    [[ "$allow_fallback" == "1" ]] && af="true"

    local jq_filter='
        .data[]
        | select(
            (.gameVersions[] == $mc_version) or
            (
              $allow_fallback == "true" and (
                (.gameVersions[] == $mc_major_minor) or
                (.gameVersions[] == $mc_major_minor_x) or
                (.gameVersions[] == $mc_major_minor_0)
              )
            )
          )
        | {url: .downloadUrl,
           dependencies: (.dependencies // []
             | map(select(.relationType == 3) | .modId))}
        | @base64
    '
    local jq_result
    jq_result=$(printf "%s" "$version_json" | jq -r \
        --arg mc_version "$target_version" \
        --arg mc_major_minor "$mc_major_minor" \
        --arg mc_major_minor_x "$mc_major_minor_x" \
        --arg mc_major_minor_0 "$mc_major_minor_0" \
        --arg allow_fallback "$af" \
        "$jq_filter" 2>/dev/null | head -n1)

    [[ -z "$jq_result" ]] && return 1
    local decoded url deps
    decoded=$(echo "$jq_result" | base64 --decode)
    url=$(echo "$decoded" | jq -r '.url')
    deps=$(echo "$decoded" | jq -r '.dependencies[]?' | tr '\n' ' ')
    printf '%s\t%s\n' "$url" "$deps"
}

# check_modrinth_mod: Check if a Modrinth mod is compatible with MC_VERSION,
# via the shared match_modrinth_version ladder (Fix #88). Modrinth is the
# preferred platform — better API, more reliable data than CurseForge.
# Inputs:
#   $1 — mod_name: human-readable name, for logging
#   $2 — mod_id: Modrinth project ID
#   Globals: MC_VERSION, MODRINTH_API_BASE (read)
# Outputs:
#   side effect — appends to SUPPORTED_MODS/MOD_DESCRIPTIONS/MOD_URLS/
#                 MOD_IDS/MOD_TYPES/MOD_DEPENDENCIES on match
#   return — 0 if a compatible Fabric version was found, 1 otherwise
check_modrinth_mod() {
    local mod_name="$1"     # Human-readable mod name
    local mod_id="$2"       # Modrinth project ID (e.g., "P7dR8mSH" for Fabric API)
    local api_url="${MODRINTH_API_BASE:-https://api.modrinth.com/v2}"
    api_url="${api_url}/project/$mod_id/version"
    
    # Create temporary file for API response
    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        print_warning "mktemp failed for $mod_name"
        return 1
    fi
    
    # Fetch all version data for this mod from Modrinth API
    # Make HTTP request to Modrinth API and capture both response and status code
    # Fix #51 (D14): fetch_url_status replaces the bare curl -w call.
    local http_code
    http_code=$(fetch_url_status "$api_url" "$tmp_body")
    local version_json
    version_json=$(cat "$tmp_body")
    rm "$tmp_body"
    
    # Validate API response (must be HTTP 200 and valid JSON)
    if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
        print_warning "Mod $mod_name ($mod_id) is not compatible with $MC_VERSION (API error)"
        return 1
    fi
    
    # Fix #88: canonical ladder (exact -> major.minor -> .x -> .0), shared
    # with version_management.sh's check_mod_version_compatibility. The old
    # STAGE 3 here re-ran the identical exact+fallback criteria as one
    # combined query and was therefore provably unreachable dead code
    # (STAGE 1/2 already tried every version string STAGE 3 could match,
    # with the same guard) — dropped, not "kept for safety", since it
    # never changed the outcome.
    local file_url=""     # Download URL for compatible mod file
    local dep_ids=""      # Space-separated list of dependency mod IDs
    local match
    if match=$(match_modrinth_version "$version_json" "$MC_VERSION" 1) \
        && [[ -n "$match" ]]; then
        file_url="${match%%$'\t'*}"
        dep_ids="${match#*$'\t'}"
    fi

    # Final result processing: Add to supported mods if we found a compatible version
    if [[ -n "$file_url" && "$file_url" != "null" ]]; then
        SUPPORTED_MODS+=("$mod_name")          # Add to list of compatible mods
        MOD_DESCRIPTIONS+=("")                  # Placeholder for description
        MOD_URLS+=("$file_url")                # Store download URL
        MOD_IDS+=("$mod_id")                   # Store Modrinth project ID
        MOD_TYPES+=("modrinth")                # Mark as Modrinth mod
        MOD_DEPENDENCIES+=("$dep_ids")         # Store dependency information
        print_success "✅ $mod_name (Modrinth)"
        return 0
    else
        local fabric_release_count=0
        if command -v jq >/dev/null 2>&1; then
            fabric_release_count=$(printf "%s" "$version_json" | jq -r '[.[] | select(any(.loaders[]?; . == "fabric"))] | length' 2>/dev/null || echo "0")
        fi
        if [[ "$fabric_release_count" == "0" ]]; then
            print_warning "❌ $mod_name ($mod_id) - no Fabric versions found on Modrinth"
        else
            print_warning "❌ $mod_name ($mod_id) - no compatible Fabric version for Minecraft $MC_VERSION"
        fi
        return 1
    fi
}

# check_curseforge_mod: Check CurseForge mod compatibility, via the shared
# match_curseforge_version ladder (Fix #88). CurseForge requires API key
# authentication (token fetched via utilities.sh:get_curseforge_api_token)
# and has more restrictive access than Modrinth.
# Inputs:
#   $1 — mod_name: human-readable name, for logging
#   $2 — cf_project_id: CurseForge project ID (numeric)
#   Globals: MC_VERSION, CURSEFORGE_API_BASE (read)
# Outputs:
#   side effect — appends to SUPPORTED_MODS/MOD_DESCRIPTIONS/MOD_URLS/
#                 MOD_IDS/MOD_TYPES/MOD_DEPENDENCIES on match
#   return — 0 if a compatible Fabric file was found, 1 otherwise (API
#            error, timeout, or no compatible version — all fail-soft so
#            the overall mod scan continues)
check_curseforge_mod() {
    local mod_name="$1"           # Human-readable mod name
    local cf_project_id="$2"      # CurseForge project ID (numeric)
    local file_url=""
    local dep_ids=""
    
    local cf_api_key=""
    # Fix #47: single canonical token fetch+decrypt (was a 7x-copied
    # download+openssl-decrypt block). Fail-soft preserved: this mod is
    # skipped (return 1), the overall mod scan continues.
    if ! cf_api_key=$(get_curseforge_api_token 2>/dev/null) \
        || [[ -z "$cf_api_key" ]]; then
        print_warning \
            "Failed to obtain CurseForge API token for $mod_name (skipping)"
        return 1
    fi
    
    # Query CurseForge API with Fabric loader filter (modLoaderType=4 = Fabric)
    # Note: We filter by Fabric loader but not by game version in the URL
    # Game version filtering is done in post-processing for more flexibility
    local cf_api_url="${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
    cf_api_url="${cf_api_url}/mods/$cf_project_id/files?modLoaderType=4"
    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        print_warning "mktemp failed for CurseForge API call"
        return 1
    fi
    
    # Make authenticated API request to CurseForge with timeout
    local http_code
    http_code=$(timeout 15 curl -s -L -w "%{http_code}" -o "$tmp_body" -H "x-api-key: $cf_api_key" "$cf_api_url" 2>/dev/null)
    local curl_exit=$?
    local version_json
    version_json=$(cat "$tmp_body")
    rm "$tmp_body"

    # Check for timeout or API failure
    if [[ $curl_exit -eq 124 ]]; then
        print_warning "❌ $mod_name ($cf_project_id) - CurseForge API timeout"
        return 1
    elif [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
        print_warning "❌ $mod_name ($cf_project_id) - API error (HTTP $http_code)"
        return 1
    fi

    # Fix #88: canonical guard + ladder, shared with
    # get_curseforge_download_url (guard only — its tier list genuinely
    # differs) and version_management.sh's check_mod_version_compatibility
    # (guard + ladder, via match_curseforge_version).
    local mc_major_minor mc_patch_version
    mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
    mc_patch_version=$(echo "$MC_VERSION" \
        | grep -oE '^[0-9]+\.[0-9]+\.([0-9]+)' | grep -oE '[0-9]+$')

    local standalone="" highest="" allow_fallback="1"
    if [[ -n "$mc_patch_version" ]]; then
        standalone=$(printf "%s" "$version_json" | jq -r \
            --arg mm "$mc_major_minor" '
            .data[] | select(any(.gameVersions[]?; . == $mm)) | .id' \
            2>/dev/null | head -n1)
        highest=$(printf "%s" "$version_json" | jq -r \
            --arg mm "$mc_major_minor" '
            [.data[]? | .gameVersions[]?
             | select(startswith($mm + ".") and (split(".") | length == 3))
             | (split(".")[2] | tonumber?)]
            | map(select(. != null))
            | if length > 0 then max else empty end' 2>/dev/null)
    fi
    _version_fallback_allowed "$mc_patch_version" "$standalone" "$highest" \
        || allow_fallback="0"

    local match
    if match=$(match_curseforge_version "$version_json" "$MC_VERSION" \
        "$allow_fallback") && [[ -n "$match" ]]; then
        file_url="${match%%$'\t'*}"
        dep_ids="${match#*$'\t'}"
    fi

    # Process the result if we found a compatible version
    if [[ -n "$file_url" && "$file_url" != "null" ]]; then
        # Add to supported mods list with CurseForge-specific information
        SUPPORTED_MODS+=("$mod_name")
        MOD_DESCRIPTIONS+=("")                 # Placeholder for description
        MOD_URLS+=("$file_url")
        MOD_IDS+=("$cf_project_id")           # Store numeric CurseForge project ID
        MOD_TYPES+=("curseforge")             # Mark as CurseForge mod
        MOD_DEPENDENCIES+=("$dep_ids")        # Store CurseForge dependency IDs
        print_success "✅ $mod_name (CurseForge)"
        return 0
    else
        local fabric_file_count=0
        if command -v jq >/dev/null 2>&1; then
            fabric_file_count=$(printf "%s" "$version_json" | jq -r '.data | length' 2>/dev/null || echo "0")
        fi
        if [[ "$fabric_file_count" == "0" ]]; then
            print_warning "❌ $mod_name ($cf_project_id) - no Fabric files found on CurseForge"
        else
            print_warning "❌ $mod_name ($cf_project_id) - no compatible Fabric file for Minecraft $MC_VERSION"
        fi
        return 1
    fi
}

# resolve_all_dependencies: Automatically resolve dependencies (single-level,
# API-based) for every mod currently in FINAL_MOD_INDEXES. Intra-list
# mods.conf dependencies should already be resolved by resolve_conf_
# dependencies before this runs; this pass catches transitive/external deps.
# Inputs:
#   Globals: FINAL_MOD_INDEXES, MOD_IDS, MOD_TYPES, SUPPORTED_MODS (read)
# Outputs:
#   side effect — appends newly discovered dependency indexes to
#                 FINAL_MOD_INDEXES (internal deps) or the SUPPORTED_MODS/
#                 MOD_* arrays plus FINAL_MOD_INDEXES (external deps, via
#                 fetch_and_add_external_mod)
resolve_all_dependencies() {
    print_header "🔗 AUTOMATIC DEPENDENCY RESOLUTION"
    print_progress "Automatically resolving mod dependencies..."
    
    # Check if we have any mods to process
    local final_mod_count=0
    if [[ ${#FINAL_MOD_INDEXES[@]} -gt 0 ]]; then
        final_mod_count=${#FINAL_MOD_INDEXES[@]}
    fi
    if [[ $final_mod_count -eq 0 ]]; then
        print_info "No mods selected for dependency resolution"
        return 0
    fi
    
    local initial_mod_count=$final_mod_count
    print_info "Starting dependency resolution with $initial_mod_count selected mods"
    
    # Simplified single-pass dependency resolution to avoid hangs
    local -A processed_mods
    local original_mod_indexes=("${FINAL_MOD_INDEXES[@]}")  # Copy original list
    
    # Process each originally selected mod for immediate dependencies only
    for idx in "${original_mod_indexes[@]}"; do
        local mod_id="${MOD_IDS[$idx]}"
        local mod_type="${MOD_TYPES[$idx]}"
        local mod_name="${SUPPORTED_MODS[$idx]}"
        
        # Skip if already processed
        if [[ -n "${processed_mods[$mod_id]:-}" ]]; then
            continue
        fi
        
        processed_mods["$mod_id"]=1
        print_info "   → Checking dependencies for: $mod_name"
        
        # Get dependencies from API based on mod type
        local deps=""
        case "$mod_type" in
            "modrinth")
                deps=$(resolve_modrinth_dependencies_api "$mod_id" 2>/dev/null || echo "")
                ;;
            "curseforge")
                deps=$(resolve_curseforge_dependencies_api "$mod_id" 2>/dev/null || echo "")
                ;;
        esac
        
        # Process found dependencies (single level only)
        if [[ -n "$deps" && "$deps" != " " ]]; then
            print_info "     → Found dependencies: $deps"
            for dep_id in $deps; do
                if [[ -n "$dep_id" && "$dep_id" != " " ]]; then
                    # Validate dependency ID format - skip invalid IDs that look like mod names
                    if [[ "$dep_id" =~ ^[A-Za-z]+$ ]] && [[ ${#dep_id} -gt 12 ]]; then
                        print_warning "       → Skipping invalid dependency ID (appears to be mod name): $dep_id"
                        continue
                    fi
                    
                    # Additional validation - CurseForge IDs should be numeric, Modrinth IDs should be alphanumeric with specific patterns
                    if [[ "$dep_id" =~ ^[0-9]+$ ]]; then
                        # Valid CurseForge ID (numeric)
                        dep_platform="curseforge"
                    elif [[ "$dep_id" =~ ^[A-Za-z0-9]{6,12}$ ]] || [[ "$dep_id" =~ ^[A-Za-z0-9_-]{3,}$ ]]; then
                        # Valid Modrinth ID (alphanumeric, 6-12 chars, or with dashes/underscores)
                        dep_platform="modrinth"
                    else
                        print_warning "       → Skipping dependency with invalid ID format: $dep_id"
                        continue
                    fi
                    
                    # Check if dependency is already in our mod list
                    local found_internal=false
                    for i in "${!MOD_IDS[@]}"; do
                        if [[ "${MOD_IDS[$i]}" == "$dep_id" ]]; then
                            # Add to final selection if not already there
                            local already_selected=false
                            for existing_idx in "${FINAL_MOD_INDEXES[@]}"; do
                                if [[ "$existing_idx" == "$i" ]]; then
                                    already_selected=true
                                    break
                                fi
                            done
                            
                            if [[ "$already_selected" == false ]]; then
                                FINAL_MOD_INDEXES+=("$i")
                                print_info "       → Added internal dependency: ${SUPPORTED_MODS[$i]}"
                            fi
                            found_internal=true
                            break
                        fi
                    done
                    
                    # If not found internally, try to fetch as external dependency with timeout
                    if [[ "$found_internal" == false ]]; then
                        print_info "       → Fetching external dependency: $dep_id"
                        
                        # Fetch external dependency (timeout handled within the function)
                        if fetch_and_add_external_mod "$dep_id" "$dep_platform"; then
                            print_info "       → Successfully added external dependency: $dep_id"
                        else
                            print_warning "       → Failed to fetch external dependency: $dep_id"
                            print_info "         (This is often due to version incompatibility and can be safely ignored)"
                        fi
                    fi
                fi
            done
        else
            print_info "     → No dependencies found"
        fi
    done
    
    local updated_mod_count=0
    if [[ ${#FINAL_MOD_INDEXES[@]} -gt 0 ]]; then
        updated_mod_count=${#FINAL_MOD_INDEXES[@]}
    fi
    local added_count=$((updated_mod_count - initial_mod_count))
    
    print_success "Dependency resolution complete!"
    print_info "Added $added_count dependencies ($initial_mod_count → $updated_mod_count total mods)"
}

# resolve_mod_dependencies: Look up a mod's platform in MOD_IDS/MOD_TYPES
# and delegate to the matching platform-specific resolver.
# Inputs:
#   $1 — mod_id: mod ID to resolve dependencies for
#   Globals: MOD_IDS, MOD_TYPES, SUPPORTED_MODS (read)
# Outputs:
#   stdout — space-separated dependency mod IDs
#   return — 1 if mod_id isn't found in MOD_IDS or its platform is unknown
resolve_mod_dependencies() {
    local mod_id="$1"
    
    # Find mod in our arrays to determine platform type
    local mod_type=""
    local mod_name=""
    for i in "${!MOD_IDS[@]}"; do
        if [[ "${MOD_IDS[$i]}" == "$mod_id" ]]; then
            mod_type="${MOD_TYPES[$i]}"
            mod_name="${SUPPORTED_MODS[$i]}"
            break
        fi
    done
    
    if [[ -z "$mod_type" ]]; then
        return 1
    fi
    
    # Route to appropriate platform-specific dependency resolver
    case "$mod_type" in
        "modrinth")
            resolve_modrinth_dependencies "$mod_id" "$mod_name"
            ;;
        "curseforge")
            resolve_curseforge_dependencies "$mod_id" "$mod_name"
            ;;
        *)
            print_warning "Unknown mod type: $mod_type for $mod_name"
            return 1
            ;;
    esac
}

# resolve_modrinth_dependencies: Get required dependencies from the Modrinth
# API for the version matching MC_VERSION (exact, then major.minor, then
# major.minor.x — a narrower ladder than match_modrinth_version's, kept
# as-is; not routed through the Fix #88 shared ladder).
# Inputs:
#   $1 — mod_id: Modrinth project ID
#   $2 — mod_name: human-readable name, for logging (unused directly here)
#   Globals: MC_VERSION, MODRINTH_API_BASE (read)
# Outputs:
#   stdout — space-separated required dependency mod IDs, or empty
#   return — 1 on API/JSON error, 0 otherwise
resolve_modrinth_dependencies() {
    local mod_id="$1"
    local mod_name="$2"
    local api_url="${MODRINTH_API_BASE:-https://api.modrinth.com/v2}"
    api_url="${api_url}/project/$mod_id/version"
    
    # Create temporary file for API response
    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        return 1
    fi
    
    # Fetch version data from Modrinth API
    # Fix #51 (D14): fetch_url_status replaces the bare curl -w call.
    local http_code
    http_code=$(fetch_url_status "$api_url" "$tmp_body")
    local version_json
    version_json=$(cat "$tmp_body")
    rm "$tmp_body"
    
    # Validate API response
    if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
        return 1
    fi
    
    # Use the same version matching logic as mod compatibility checking
    local mc_major_minor
    mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
    
    # Try exact version match first
    local dep_ids
    dep_ids=$(printf "%s" "$version_json" | jq -r \
        --arg v "$MC_VERSION" \
        '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' \
        2>/dev/null | tr '\n' ' ')
    
    # Try major.minor version if exact match failed
    if [[ -z "$dep_ids" ]]; then
        dep_ids=$(printf "%s" "$version_json" | jq -r \
            --arg v "$mc_major_minor" \
            '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' \
            2>/dev/null | tr '\n' ' ')
    fi
    
    # Try wildcard version (1.21.x) if still no results
    if [[ -z "$dep_ids" ]]; then
        local mc_major_minor_x="$mc_major_minor.x"
        dep_ids=$(printf "%s" "$version_json" | jq -r \
            --arg v "$mc_major_minor_x" \
            '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' \
            2>/dev/null | tr '\n' ' ')
    fi
    
    # Clean up and return dependency IDs
    dep_ids=$(echo "$dep_ids" | xargs)  # Trim whitespace
    if [[ -n "$dep_ids" ]]; then
        echo "$dep_ids"
    fi
}

# resolve_curseforge_dependencies: Get required dependencies from the
# CurseForge API for the file matching MC_VERSION (exact, major.minor,
# major.minor.x, major.minor.0 — combined single query, no fallback guard;
# a narrower ladder than match_curseforge_version's, kept as-is).
# Inputs:
#   $1 — mod_id: CurseForge project ID (numeric)
#   $2 — mod_name: human-readable name, for logging (unused directly here)
#   Globals: MC_VERSION, CURSEFORGE_API_BASE (read)
# Outputs:
#   stdout — space-separated required dependency mod IDs, or empty
#   return — 1 if the CurseForge API token/response is unavailable, 0
#            otherwise
resolve_curseforge_dependencies() {
    local mod_id="$1"
    local mod_name="$2"
    
    # Fix #47: single canonical token fetch+decrypt (was a 7x-copied
    # download+openssl-decrypt block).
    local cf_api_key
    if ! cf_api_key=$(get_curseforge_api_token 2>/dev/null) \
        || [[ -z "$cf_api_key" ]]; then
        return 1
    fi

    # Query CurseForge API with Fabric loader filter
    local cf_api_url="${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
    cf_api_url="${cf_api_url}/mods/$mod_id/files?modLoaderType=4"
    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        return 1
    fi
    
    # Make authenticated API request
    local http_code
    http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_body" -H "x-api-key: $cf_api_key" "$cf_api_url" 2>/dev/null)
    local version_json
    version_json=$(cat "$tmp_body")
    rm "$tmp_body"

    # Validate API response
    if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
        return 1
    fi

    # Extract dependencies using CurseForge API structure
    local mc_major_minor
    mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
    local mc_major_minor_x="$mc_major_minor.x"
    local mc_major_minor_0="$mc_major_minor.0"
    
    # CurseForge dependency extraction with version matching
    local dep_ids
    dep_ids=$(printf "%s" "$version_json" | jq -r \
        --arg mc_version "$MC_VERSION" \
        --arg mc_major_minor "$mc_major_minor" \
        --arg mc_major_minor_x "$mc_major_minor_x" \
        --arg mc_major_minor_0 "$mc_major_minor_0" \
        '.data[] | select(
            ((.gameVersions[] == $mc_version) or
             (.gameVersions[] == $mc_major_minor) or
             (.gameVersions[] == $mc_major_minor_x) or
             (.gameVersions[] == $mc_major_minor_0))
        ) | .dependencies[]? | select(.relationType == 3) | .modId' \
        2>/dev/null | tr '\n' ' ')
    
    # Clean up and return dependency IDs
    dep_ids=$(echo "$dep_ids" | xargs)  # Trim whitespace
    if [[ -n "$dep_ids" ]]; then
        echo "$dep_ids"
    fi
}

# resolve_modrinth_dependencies_api: Get required dependencies for a
# Modrinth mod, used by resolve_all_dependencies' single-pass API scan.
# Falls back to fallback_dependencies (version_management.sh) if the API
# call or jq extraction yields nothing.
# Inputs:
#   $1 — mod_id: Modrinth project ID or slug
#   Globals: MC_VERSION, MODRINTH_API_BASE (read)
# Outputs:
#   stdout — space-separated dependency mod IDs, or "" (prints even on API
#            failure — callers capture via command substitution)
#   return — 1 only if mktemp fails; 0 otherwise (including API failure)
resolve_modrinth_dependencies_api() {
    local mod_id="$1"
    local dependencies=""
    
    # Skip if essential commands are not available
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "" # Return empty dependencies
        return 0
    fi
    
    # Create temporary file for large API response to avoid "Argument list too long" error
    local tmp_file
    tmp_file=$(mktemp) || return 1
    
    # Get the latest version for the Minecraft version we're using with timeout
    local versions_url="${MODRINTH_API_BASE:-https://api.modrinth.com/v2}"
    versions_url="${versions_url}/project/$mod_id/version"
    
    # Fix #51 (D14): fetch_url replaces the curl/wget branches.
    if ! fetch_url "$versions_url" "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        echo ""
        return 0
    fi
    
    # Check if we got valid JSON data
    if [[ ! -s "$tmp_file" ]] || ! jq -e . < "$tmp_file" > /dev/null 2>&1; then
        rm -f "$tmp_file"
        echo ""
        return 0
    fi

    # Use simpler approach: find fabric versions for our Minecraft version
    if command -v jq >/dev/null 2>&1; then
        local mc_major_minor
        mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')  # "1.21" from "1.21.3" or "26.1" from "26.1.1"
        
        # Simple jq filter to get dependencies from compatible fabric versions with strict matching
        # Use temporary file to avoid command line length limits
        dependencies=$(jq -r "
            .[] 
            | select(.loaders[]? == \"fabric\") 
            | select(.game_versions[]? | (. == \"$MC_VERSION\" or . == \"$mc_major_minor\" or . == \"${mc_major_minor}.x\" or . == \"${mc_major_minor}.0\"))
            | .dependencies[]? 
            | select(.dependency_type == \"required\") 
            | .project_id
        " < "$tmp_file" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    else
        # Fallback to basic grep parsing if jq is not available
        local deps_section=$(grep -o '"dependencies":\[[^]]*\]' "$tmp_file" | head -1)
        if [[ -n "$deps_section" ]]; then
            # Extract project_id values from dependencies
            local dep_ids=$(echo "$deps_section" | grep -o '"project_id":"[^"]*"' | sed 's/"project_id":"//g' | sed 's/"//g')
            dependencies="$dep_ids"
        fi
    fi

    # Clean up temporary file
    rm -f "$tmp_file"
    
    # Use fallback dependencies if API call failed
    if [[ -z "$dependencies" ]]; then
        dependencies=$(fallback_dependencies "$mod_id" "modrinth")
    fi
    
    echo "$dependencies"
}

# resolve_curseforge_dependencies_api: Get required dependencies for a
# CurseForge mod, used by resolve_all_dependencies' single-pass API scan.
# Three sequential API calls (mod info, files list, file detail) rather
# than the combined query the other CurseForge resolver uses. Falls back to
# fallback_dependencies, then a hardcoded JEI-era special case.
# Inputs:
#   $1 — mod_id: CurseForge project ID (numeric)
#   Globals: MC_VERSION, CURSEFORGE_API_BASE (read)
# Outputs:
#   stdout — space-separated dependency mod IDs, or "" (prints even on API
#            failure — callers capture via command substitution)
#   return — 1 if the CurseForge API token is unavailable, 0 otherwise
resolve_curseforge_dependencies_api() {
    local mod_id="$1"
    local dependencies=""
    
    # Fix #47: single canonical token fetch+decrypt (was a 7x-copied
    # download+openssl-decrypt block).
    local api_token
    if ! api_token=$(get_curseforge_api_token 2>/dev/null) \
        || [[ -z "$api_token" ]]; then
        echo ""
        return 1
    fi
    
    # Fetch mod info from CurseForge API with authentication
    local api_url="${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
    api_url="${api_url}/mods/$mod_id"
    local temp_file=$(mktemp)
    
    if command -v curl >/dev/null 2>&1; then
        curl -s -H "x-api-key: $api_token" -o "$temp_file" "$api_url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --header="x-api-key: $api_token" -O "$temp_file" "$api_url" 2>/dev/null
    else
        rm -f "$temp_file"
        echo ""
        return 1
    fi
    
    # Extract required dependencies from mod info
    if [[ -s "$temp_file" ]] && command -v jq >/dev/null 2>&1; then
        # Get the latest files for this mod
        local files_url="${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
        files_url="${files_url}/mods/$mod_id/files?modLoaderType=4"
        local files_temp=$(mktemp)
        
        if command -v curl >/dev/null 2>&1; then
            curl -s -H "x-api-key: $api_token" -o "$files_temp" "$files_url" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then
            wget -q --header="x-api-key: $api_token" -O "$files_temp" "$files_url" 2>/dev/null
        fi
        
        if [[ -s "$files_temp" ]]; then
            # Find the most recent compatible file
            local mc_major_minor
            mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
            
            # Extract file ID from the most recent compatible file with strict version matching
            local file_id=$(jq -r --arg v "$MC_VERSION" --arg mmv "$mc_major_minor" '.data[] | select(.gameVersions[] == $v or .gameVersions[] == $mmv or .gameVersions[] == ($mmv + ".x") or .gameVersions[] == ($mmv + ".0")) | .id' "$files_temp" 2>/dev/null | head -n1)
            
            if [[ -n "$file_id" && "$file_id" != "null" ]]; then
                # Get dependencies for this specific file
                local file_info_url=\
"${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
                file_info_url="${file_info_url}/mods/$mod_id/files/$file_id"
                local file_info_temp=$(mktemp)
                
                if command -v curl >/dev/null 2>&1; then
                    curl -s -H "x-api-key: $api_token" -o "$file_info_temp" "$file_info_url" 2>/dev/null
                elif command -v wget >/dev/null 2>&1; then
                    wget -q --header="x-api-key: $api_token" -O "$file_info_temp" "$file_info_url" 2>/dev/null
                fi
                
                if [[ -s "$file_info_temp" ]]; then
                    # Extract required dependencies
                    dependencies=$(jq -r '.data.dependencies[]? | select(.relationType == 3) | .modId' "$file_info_temp" 2>/dev/null | tr '\n' ' ')
                fi
                
                rm -f "$file_info_temp"
            fi
        fi
        
        rm -f "$files_temp"
    fi
    
    rm -f "$temp_file"
    
    # Use fallback dependencies if API call failed
    if [[ -z "$dependencies" ]]; then
        dependencies=$(fallback_dependencies "$mod_id" "curseforge")
    fi
    # Critical dependency fallbacks (legacy 1.21.1 era — kept for backward compat)
    if [[ -z "$dependencies" ]]; then
        case "$mod_id" in
            "238222")  # JEI
                dependencies="306612"  # Fabric API
                ;;
        esac
    fi
    
    echo "$dependencies"
}

# fetch_and_add_external_mod: Fetch metadata for a dependency mod not
# already tracked in SUPPORTED_MODS/MOD_IDS, and add it to those arrays plus
# FINAL_MOD_INDEXES. Used by resolve_all_dependencies for transitive deps.
# Inputs:
#   $1 — ext_mod_id: the external mod ID
#   $2 — ext_mod_type: platform ("modrinth" or "curseforge")
#   Globals: MODRINTH_API_BASE, CURSEFORGE_API_BASE (read)
# Outputs:
#   side effect — appends to SUPPORTED_MODS/MOD_DESCRIPTIONS/MOD_IDS/
#                 MOD_TYPES/MOD_URLS/MOD_DEPENDENCIES and FINAL_MOD_INDEXES
#   return — 0 if a mod entry was added (name resolved, or a known fallback
#            name applied), 1 if nothing could be added
fetch_and_add_external_mod() {
    local ext_mod_id="$1"
    local ext_mod_type="$2"
    local success=false
    
    case "$ext_mod_type" in
        "modrinth")
            # Create temporary file for downloading large JSON responses
            local temp_file=$(mktemp)
            local api_url="${MODRINTH_API_BASE:-https://api.modrinth.com/v2}"
            api_url="${api_url}/project/$ext_mod_id"
            
            # Download to temp file without size restrictions
            local download_success=false
            # Fix #51 (D14): fetch_url replaces the curl/wget branches.
            if fetch_url "$api_url" "$temp_file" 2>/dev/null; then
                download_success=true
            fi
            
            if [[ "$download_success" == true && -s "$temp_file" ]]; then
                # Check if the file contains valid JSON (not an error)
                if ! grep -q '"error"' "$temp_file" 2>/dev/null; then
                    # Extract mod name from JSON file using jq if available, fallback to grep
                    local mod_title=""
                    local mod_description=""
                    
                    if command -v jq >/dev/null 2>&1; then
                        mod_title=$(jq -r '.title // ""' "$temp_file" 2>/dev/null)
                        mod_description=$(jq -r '.description // ""' "$temp_file" 2>/dev/null)
                    else
                        # Fallback to basic grep parsing
                        mod_title=$(grep -o '"title":"[^"]*"' "$temp_file" | sed 's/"title":"//g' | sed 's/"//g' | head -1)
                        mod_description=$(grep -o '"description":"[^"]*"' "$temp_file" | sed 's/"description":"//g' | sed 's/"//g' | head -1)
                    fi
                    
                    if [[ -n "$mod_title" ]]; then
                        # Add to our arrays (keep all arrays synchronized)
                        SUPPORTED_MODS+=("$mod_title")
                        MOD_DESCRIPTIONS+=("${mod_description:-External dependency}")
                        MOD_IDS+=("$ext_mod_id")
                        MOD_TYPES+=("modrinth")
                        MOD_URLS+=("")  # Empty URL - will be resolved during download
                        MOD_DEPENDENCIES+=("")  # Will be populated if needed
                        
                        # Add to final selection
                        local new_index=$((${#SUPPORTED_MODS[@]} - 1))
                        FINAL_MOD_INDEXES+=("$new_index")
                        success=true
                    fi
                fi
            fi
            
            # Clean up temp file
            rm -f "$temp_file" 2>/dev/null
            ;;
            
        "curseforge")
            # Use the new robust CurseForge API integration
            local mod_title=""
            local mod_description=""
            local download_url=""
            
            # Fix #47: single canonical token fetch+decrypt (was a 7x-copied
            # download+openssl-decrypt block).
            local api_token
            if api_token=$(get_curseforge_api_token 2>/dev/null) \
                && [[ -n "$api_token" ]]; then
                # Fetch mod info from CurseForge API
                local api_url
                api_url="${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
                api_url="$api_url/mods/$ext_mod_id"
                local temp_file=$(mktemp)

                if command -v curl >/dev/null 2>&1; then
                    curl -s -H "x-api-key: $api_token" \
                        -o "$temp_file" "$api_url" 2>/dev/null
                elif command -v wget >/dev/null 2>&1; then
                    wget -q --header="x-api-key: $api_token" \
                        -O "$temp_file" "$api_url" 2>/dev/null
                fi

                # Extract mod title and description
                if [[ -s "$temp_file" ]] && command -v jq >/dev/null 2>&1; then
                    mod_title=$(jq -r '.data.name // ""' "$temp_file" \
                        2>/dev/null)
                    mod_description=$(jq -r '.data.summary // ""' \
                        "$temp_file" 2>/dev/null)
                fi

                rm -f "$temp_file"

                # Get download URL using our robust function
                download_url=$(get_curseforge_download_url "$ext_mod_id")
            fi

            # Fallback for known mods if API fails
            if [[ -z "$mod_title" ]]; then
                case "$ext_mod_id" in
                    "DOUdJVEm")  # Controlify
                        mod_title="Controlify"
                        mod_description="Adds controller support to Minecraft"
                        ;;
                    "306612")  # Fabric API
                        mod_title="Fabric API"
                        mod_description="Essential modding API for Fabric"
                        ;;
                    "634179")  # Framework
                        mod_title="Framework"
                        mod_description="Library mod for various mods"
                        ;;
                    *)
                        mod_title="External Dependency (CF:$ext_mod_id)"
                        mod_description="External dependency from CurseForge"
                        ;;
                esac
            fi
            
            # Add to our arrays
            SUPPORTED_MODS+=("$mod_title")
            MOD_DESCRIPTIONS+=("${mod_description:-External dependency from CurseForge}")
            MOD_IDS+=("$ext_mod_id")
            MOD_TYPES+=("curseforge")
            MOD_URLS+=("$download_url")  # May be empty if API failed
            MOD_DEPENDENCIES+=("")  # Will be populated if needed
            
            local new_index=$((${#SUPPORTED_MODS[@]} - 1))
            FINAL_MOD_INDEXES+=("$new_index")
            success=true
            ;;
    esac
    
    if [[ "$success" == true ]]; then
        return 0
    else
        return 1
    fi
}

# get_curseforge_download_url: Find a compatible CurseForge mod file for
# MC_VERSION and return its download URL. Fix #88: shares the
# _version_fallback_allowed guard and per-tier _curseforge_tier_url lookup
# with the other CurseForge call sites, but keeps its OWN tier list — it has
# a previous-patch tier they don't, and lacks the .0 tier they have (a real,
# preserved divergence — not routed through match_curseforge_version).
# Inputs:
#   $1 — mod_id: CurseForge project ID (numeric)
#   Globals: MC_VERSION, CURSEFORGE_API_BASE (read)
# Outputs:
#   stdout — download URL for the compatible mod file, or empty string
#   return — 1 if the CurseForge API token/files list is unavailable, 0
#            otherwise (0 even when no compatible file is found — callers
#            judge success via the string, not the exit code)
get_curseforge_download_url() {
    local mod_id="$1"
    local download_url=""
    
    # Fix #47: single canonical token fetch+decrypt (was a 7x-copied
    # download+openssl-decrypt block).
    local api_token
    if ! api_token=$(get_curseforge_api_token 2>/dev/null) \
        || [[ -z "$api_token" ]]; then
        echo ""
        return 1
    fi

    # Fetch mod files from CurseForge API with Fabric loader filter
    local files_url="${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
    files_url="${files_url}/mods/$mod_id/files?modLoaderType=4"
    local temp_file=$(mktemp)
    
    if command -v curl >/dev/null 2>&1; then
        curl -s -H "x-api-key: $api_token" -o "$temp_file" "$files_url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --header="x-api-key: $api_token" -O "$temp_file" "$files_url" 2>/dev/null
    else
        rm -f "$temp_file"
        echo ""
        return 1
    fi
    
    # Parse response and find compatible file.
    # Fix #88: this ladder is intentionally NOT routed through
    # match_curseforge_version — it genuinely differs from the other two CF
    # call sites (a previous-patch tier they don't have; no .0 tier they
    # do have), a real divergence preserved as-is. It DOES share the
    # _version_fallback_allowed guard (identical computation to
    # check_curseforge_mod's) and the single-tier _curseforge_tier_url
    # query (same per-tier lookup, different tier list/order).
    if [[ -s "$temp_file" ]] && command -v jq >/dev/null 2>&1; then
        local version_json
        version_json=$(cat "$temp_file")
        local mc_major_minor
        mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
        local mc_patch_version
        mc_patch_version=$(echo "$MC_VERSION" \
            | grep -oE '^[0-9]+\.[0-9]+\.([0-9]+)' | grep -oE '[0-9]+$')

        local standalone="" highest=""
        if [[ -n "$mc_patch_version" ]]; then
            standalone=$(printf "%s" "$version_json" | jq -r \
                --arg mm "$mc_major_minor" '
                .data[] | select(any(.gameVersions[]?; . == $mm)) | .id' \
                2>/dev/null | head -n1)
            highest=$(printf "%s" "$version_json" | jq -r \
                --arg mm "$mc_major_minor" '
                [.data[]? | .gameVersions[]?
                 | select(startswith($mm + ".") and (split(".")|length==3))
                 | (split(".")[2] | tonumber?)]
                | map(select(. != null))
                | if length > 0 then max else empty end' 2>/dev/null)
        fi
        local should_try_fallback=true
        _version_fallback_allowed "$mc_patch_version" "$standalone" \
            "$highest" || should_try_fallback=false

        # Try exact version match first.
        download_url=$(_curseforge_tier_url "$version_json" "$MC_VERSION")

        # Try major.minor version if exact match failed and fallback is allowed
        if [[ "$should_try_fallback" == true ]] \
            && [[ -z "$download_url" || "$download_url" == "null" ]]; then
            download_url=$(_curseforge_tier_url "$version_json" \
                "$mc_major_minor")
        fi

        # Try wildcard version (e.g., "1.21.x") if fallback is allowed
        if [[ "$should_try_fallback" == true ]] \
            && [[ -z "$download_url" || "$download_url" == "null" ]]; then
            download_url=$(_curseforge_tier_url "$version_json" \
                "$mc_major_minor.x")
        fi

        # Try limited previous patch version when fallback is allowed
        if [[ "$should_try_fallback" == true ]] \
            && [[ -z "$download_url" || "$download_url" == "null" ]] \
            && [[ -n "$mc_patch_version" && $mc_patch_version -gt 0 ]]; then
            # Try one patch version down (e.g., if looking for 1.21.6, try 1.21.5)
            local prev_patch=$((mc_patch_version - 1))
            download_url=$(_curseforge_tier_url "$version_json" \
                "$mc_major_minor.$prev_patch")
        fi
    fi

    rm -f "$temp_file"
    
    # Return the download URL (may be empty if not found)
    echo "$download_url"
}

# Fix #47: get_curseforge_api_token moved to modules/utilities.sh (network
# transport, sourced before this module — see install-minecraft-splitscreen.sh
# source order). This module now only CONSUMES it.

# parse_custom_mod_input: Parse a user-supplied Modrinth/CurseForge mod
# reference. Supports full URLs, prefixed IDs (mr:/cf:/modrinth:/
# curseforge:), raw Modrinth IDs/slugs, and raw numeric CurseForge IDs.
# Inputs:
#   $1 — raw_input: the raw user-typed string
#   $2 — nameref: receives "modrinth" or "curseforge" on success
#   $3 — nameref: receives the parsed platform ID/slug on success
# Outputs:
#   return — 0 on a recognized format (namerefs set), 1 if unrecognized
#            (namerefs left as empty strings)
parse_custom_mod_input() {
    local raw_input="$1"
    local -n out_platform="$2"
    local -n out_id="$3"
    out_platform=""
    out_id=""

    # Trim leading/trailing whitespace
    local cleaned
    cleaned=$(echo "$raw_input" | xargs 2>/dev/null || echo "$raw_input")
    if [[ -z "$cleaned" ]]; then
        return 1
    fi

    # Modrinth URLs (modrinth.com/mod/<id-or-slug>)
    if [[ "$cleaned" =~ modrinth\.com/(mod|plugin|datapack|resourcepack|shader)/([^/?#]+) ]]; then
        out_platform="modrinth"
        out_id="${BASH_REMATCH[2]}"
        return 0
    fi

    # CurseForge URLs with numeric project IDs (.../projects/<id>)
    if [[ "$cleaned" =~ curseforge\.com/.*/projects/([0-9]+) ]]; then
        out_platform="curseforge"
        out_id="${BASH_REMATCH[1]}"
        return 0
    fi

    # Explicit prefixes
    if [[ "$cleaned" =~ ^(modrinth|mr):([A-Za-z0-9_-]+)$ ]]; then
        out_platform="modrinth"
        out_id="${BASH_REMATCH[2]}"
        return 0
    fi
    if [[ "$cleaned" =~ ^(curseforge|cf):([0-9]+)$ ]]; then
        out_platform="curseforge"
        out_id="${BASH_REMATCH[2]}"
        return 0
    fi

    # Raw numeric values are treated as CurseForge project IDs
    if [[ "$cleaned" =~ ^[0-9]+$ ]]; then
        out_platform="curseforge"
        out_id="$cleaned"
        return 0
    fi

    # Raw Modrinth ID/slug
    if [[ "$cleaned" =~ ^[A-Za-z0-9_-]{3,}$ ]]; then
        out_platform="modrinth"
        out_id="$cleaned"
        return 0
    fi

    return 1
}

# find_existing_mod_index: Find an existing MOD_IDS/MOD_TYPES index for a
# platform + mod ID pair (used to avoid re-adding an already-tracked mod as
# a "custom" one).
# Inputs:
#   $1 — platform: "modrinth" or "curseforge"
#   $2 — mod_id
#   Globals: MOD_IDS, MOD_TYPES (read)
# Outputs:
#   stdout — matching index, or "" if not found
#   return — 0 if found, 1 if not found
find_existing_mod_index() {
    local platform="$1"
    local mod_id="$2"
    local i
    for i in "${!MOD_IDS[@]}"; do
        if [[ "${MOD_TYPES[$i]}" == "$platform" && "${MOD_IDS[$i]}" == "$mod_id" ]]; then
            echo "$i"
            return 0
        fi
    done
    echo ""
    return 1
}

# get_custom_mod_display_name: Resolve a human-readable display name for a
# custom mod, for use in prompts/logging while it's still being validated.
# Inputs:
#   $1 — platform: "modrinth" or "curseforge"
#   $2 — mod_id
#   Globals: MODRINTH_API_BASE, CURSEFORGE_API_BASE (read)
# Outputs:
#   stdout — API-resolved title/name, or a "Custom <platform> mod (<id>)"
#            placeholder if the API lookup fails
#   return — always 0
get_custom_mod_display_name() {
    local platform="$1"
    local mod_id="$2"

    if [[ "$platform" == "modrinth" ]]; then
        local api_url="${MODRINTH_API_BASE:-https://api.modrinth.com/v2}"
        api_url="${api_url}/project/$mod_id"
        local tmp_file
        tmp_file=$(mktemp)
        if [[ -n "$tmp_file" ]]; then
            # Fix #51 (D14): fetch_url replaces the curl/wget branches;
            # success is judged by the -s check below, not exit status.
            fetch_url "$api_url" "$tmp_file" 2>/dev/null || true

            if [[ -s "$tmp_file" ]] && command -v jq >/dev/null 2>&1; then
                local title
                title=$(jq -r '.title // .name // empty' "$tmp_file" 2>/dev/null)
                rm -f "$tmp_file"
                if [[ -n "$title" && "$title" != "null" ]]; then
                    echo "$title"
                    return 0
                fi
            fi
            rm -f "$tmp_file"
        fi
        echo "Custom Modrinth mod ($mod_id)"
        return 0
    fi

    local api_token=""
    if ! api_token=$(get_curseforge_api_token 2>/dev/null); then
        api_token=""
    fi
    if [[ -n "$api_token" ]]; then
        local cf_api_url="${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
        cf_api_url="${cf_api_url}/mods/$mod_id"
        local tmp_file
        tmp_file=$(mktemp)
        if [[ -n "$tmp_file" ]]; then
            if command -v curl >/dev/null 2>&1; then
                curl -s -m 12 -H "x-api-key: $api_token" -o "$tmp_file" "$cf_api_url" 2>/dev/null
            elif command -v wget >/dev/null 2>&1; then
                wget -q --timeout=12 --header="x-api-key: $api_token" -O "$tmp_file" "$cf_api_url" 2>/dev/null
            fi

            if [[ -s "$tmp_file" ]] && command -v jq >/dev/null 2>&1; then
                local name
                name=$(jq -r '.data.name // empty' "$tmp_file" 2>/dev/null)
                rm -f "$tmp_file"
                if [[ -n "$name" && "$name" != "null" ]]; then
                    echo "$name"
                    return 0
                fi
            fi
            rm -f "$tmp_file"
        fi
    fi

    echo "Custom CurseForge mod ($mod_id)"
    return 0
}

# print_supported_versions_for_custom_mod: Print the (up to 30 most recent)
# Fabric-compatible Minecraft versions for a custom mod, to help the user
# choose whether to switch MC version to support it.
# Inputs:
#   $1 — platform: "modrinth" or "curseforge"
#   $2 — mod_id
#   Globals: MODRINTH_API_BASE, CURSEFORGE_API_BASE (read)
# Outputs:
#   stdout — "  - <version>" lines, one per supported version
#   return — 0 if versions were printed, 1 if the API lookup failed
print_supported_versions_for_custom_mod() {
    local platform="$1"
    local mod_id="$2"

    print_info "Compatible Minecraft versions for this mod (Fabric):"

    if [[ "$platform" == "modrinth" ]]; then
        local api_url="${MODRINTH_API_BASE:-https://api.modrinth.com/v2}"
        api_url="${api_url}/project/$mod_id/version"
        local tmp_file
        tmp_file=$(mktemp)
        if [[ -z "$tmp_file" ]]; then
            print_warning "Could not allocate temp file to query supported versions"
            return 1
        fi

        # Fix #51 (D14): fetch_url replaces the curl/wget branches;
        # success is judged by the -s check below, not exit status.
        fetch_url "$api_url" "$tmp_file" 2>/dev/null || true

        if [[ -s "$tmp_file" ]] && command -v jq >/dev/null 2>&1; then
            local versions
            versions=$(jq -r '.[] | select(any(.loaders[]?; . == "fabric")) | .game_versions[]?' "$tmp_file" 2>/dev/null \
                | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
                | sort -Vu \
                | tail -n 30)
            rm -f "$tmp_file"

            if [[ -n "$versions" ]]; then
                echo "$versions" | while IFS= read -r v; do
                    echo "  - $v"
                done
                return 0
            fi
        fi

        rm -f "$tmp_file"
        print_warning "Could not determine supported versions from Modrinth API"
        return 1
    fi

    local api_token=""
    if ! api_token=$(get_curseforge_api_token 2>/dev/null); then
        api_token=""
    fi
    if [[ -z "$api_token" ]]; then
        print_warning "Could not access CurseForge API to list supported versions"
        return 1
    fi

    local cf_files_url="${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
    cf_files_url="${cf_files_url}/mods/$mod_id/files?modLoaderType=4"
    local tmp_file
    tmp_file=$(mktemp)
    if [[ -z "$tmp_file" ]]; then
        print_warning "Could not allocate temp file to query supported versions"
        return 1
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -s -m 15 -H "x-api-key: $api_token" -o "$tmp_file" "$cf_files_url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --header="x-api-key: $api_token" -O "$tmp_file" "$cf_files_url" 2>/dev/null
    fi

    if [[ -s "$tmp_file" ]] && command -v jq >/dev/null 2>&1; then
        local versions
        versions=$(jq -r '.data[]?.gameVersions[]?' "$tmp_file" 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
            | sort -Vu \
            | tail -n 30)
        rm -f "$tmp_file"

        if [[ -n "$versions" ]]; then
            echo "$versions" | while IFS= read -r v; do
                echo "  - $v"
            done
            return 0
        fi
    fi

    rm -f "$tmp_file"
    print_warning "Could not determine supported versions from CurseForge API"
    return 1
}

# check_modrinth_mod_strict: Strict custom-mod check — Fabric loader AND
# exact MC_VERSION match only, no ladder fallback (unlike check_modrinth_mod).
# Inputs:
#   $1 — mod_name: human-readable name, for logging
#   $2 — mod_id: Modrinth project ID
#   Globals: MC_VERSION, MODRINTH_API_BASE (read)
# Outputs:
#   side effect — appends to SUPPORTED_MODS/MOD_* on match; sets global
#                 CUSTOM_MOD_LAST_INCOMPAT_REASON ("no_fabric" /
#                 "version_mismatch" / "") for prompt_custom_mods to branch on
#   return — 0 on match, 1 otherwise
check_modrinth_mod_strict() {
    local mod_name="$1"
    local mod_id="$2"
    local api_url="${MODRINTH_API_BASE:-https://api.modrinth.com/v2}"
    api_url="${api_url}/project/$mod_id/version"

    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        print_warning "mktemp failed for $mod_name"
        return 1
    fi

    # Fix #51 (D14): fetch_url_status replaces the bare curl -w call.
    local http_code
    http_code=$(fetch_url_status "$api_url" "$tmp_body")
    local version_json
    version_json=$(cat "$tmp_body")
    rm -f "$tmp_body"

    if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . >/dev/null 2>&1; then
        print_warning "❌ $mod_name ($mod_id) - API error"
        return 1
    fi

    local file_url=""
    local dep_ids=""
    CUSTOM_MOD_LAST_INCOMPAT_REASON=""
    file_url=$(printf "%s" "$version_json" | jq -r --arg v "$MC_VERSION" '.[] | select((.loaders[]? == "fabric") and any(.game_versions[]?; . == $v)) | .files[] | select(.primary == true) | .url' 2>/dev/null | head -n1)
    if [[ -n "$file_url" && "$file_url" != "null" ]]; then
        dep_ids=$(printf "%s" "$version_json" | jq -r --arg v "$MC_VERSION" '.[] | select((.loaders[]? == "fabric") and any(.game_versions[]?; . == $v)) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null | tr '\n' ' ')
        SUPPORTED_MODS+=("$mod_name")
        MOD_DESCRIPTIONS+=("")
        MOD_URLS+=("$file_url")
        MOD_IDS+=("$mod_id")
        MOD_TYPES+=("modrinth")
        MOD_DEPENDENCIES+=("$dep_ids")
        print_success "✅ $mod_name (Modrinth)"
        CUSTOM_MOD_LAST_INCOMPAT_REASON=""
        return 0
    fi

    local fabric_release_count=0
    fabric_release_count=$(printf "%s" "$version_json" | jq -r '[.[] | select(any(.loaders[]?; . == "fabric"))] | length' 2>/dev/null || echo "0")
    if [[ "$fabric_release_count" == "0" ]]; then
        print_warning "❌ $mod_name ($mod_id) - no Fabric versions found on Modrinth"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="no_fabric"
    else
        print_warning "❌ $mod_name ($mod_id) - no exact Fabric support for Minecraft $MC_VERSION"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="version_mismatch"
    fi
    return 1
}

# check_curseforge_mod_strict: Strict custom-mod check — exact MC_VERSION
# match only, no ladder fallback (unlike check_curseforge_mod).
# Inputs:
#   $1 — mod_name: human-readable name, for logging
#   $2 — cf_project_id: CurseForge project ID (numeric)
#   Globals: MC_VERSION, CURSEFORGE_API_BASE (read)
# Outputs:
#   side effect — appends to SUPPORTED_MODS/MOD_* on match; sets global
#                 CUSTOM_MOD_LAST_INCOMPAT_REASON ("api_error" / "no_fabric"
#                 / "version_mismatch" / "") for prompt_custom_mods
#   return — 0 on match, 1 otherwise
check_curseforge_mod_strict() {
    local mod_name="$1"
    local cf_project_id="$2"
    local api_token=""
    local file_url=""
    local dep_ids=""
    CUSTOM_MOD_LAST_INCOMPAT_REASON=""

    if ! api_token=$(get_curseforge_api_token 2>/dev/null); then
        api_token=""
    fi
    if [[ -z "$api_token" ]]; then
        print_warning "❌ $mod_name ($cf_project_id) - unable to access CurseForge API token"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="api_error"
        return 1
    fi

    local cf_api_url="${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
    cf_api_url="${cf_api_url}/mods/$cf_project_id/files?modLoaderType=4"
    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        print_warning "mktemp failed for CurseForge API call"
        return 1
    fi

    local http_code
    http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_body" -H "x-api-key: $api_token" "$cf_api_url" 2>/dev/null)
    local version_json
    version_json=$(cat "$tmp_body")
    rm -f "$tmp_body"

    if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . >/dev/null 2>&1; then
        print_warning "❌ $mod_name ($cf_project_id) - API error (HTTP $http_code)"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="api_error"
        return 1
    fi

    local jq_result
    jq_result=$(printf "%s" "$version_json" | jq -r --arg mc_version "$MC_VERSION" '
        .data[]
        | select(any(.gameVersions[]?; . == $mc_version))
        | {url: .downloadUrl, dependencies: (.dependencies // [] | map(select(.relationType == 3) | .modId))}
        | @base64' 2>/dev/null | head -n1)

    if [[ -n "$jq_result" ]]; then
        local decoded
        decoded=$(echo "$jq_result" | base64 --decode)
        file_url=$(echo "$decoded" | jq -r '.url')
        dep_ids=$(echo "$decoded" | jq -r '.dependencies[]?' | tr '\n' ' ')
        SUPPORTED_MODS+=("$mod_name")
        MOD_DESCRIPTIONS+=("")
        MOD_URLS+=("$file_url")
        MOD_IDS+=("$cf_project_id")
        MOD_TYPES+=("curseforge")
        MOD_DEPENDENCIES+=("$dep_ids")
        print_success "✅ $mod_name (CurseForge)"
        CUSTOM_MOD_LAST_INCOMPAT_REASON=""
        return 0
    fi

    local fabric_file_count=0
    fabric_file_count=$(printf "%s" "$version_json" | jq -r '.data | length' 2>/dev/null || echo "0")
    if [[ "$fabric_file_count" == "0" ]]; then
        print_warning "❌ $mod_name ($cf_project_id) - no Fabric files found on CurseForge"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="no_fabric"
    else
        print_warning "❌ $mod_name ($cf_project_id) - no exact Fabric support for Minecraft $MC_VERSION"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="version_mismatch"
    fi
    return 1
}

# prompt_custom_mods: Interactive flow for adding user-supplied
# Modrinth/CurseForge mods. On an incompatible mod, offers to switch the
# selected MC version to one that supports it too (re-running the version
# and mod-compatibility pipeline) — signaled back to select_user_mods via
# return 2, since that path already re-invokes select_user_mods itself.
# Inputs:
#   $1 — nameref to an associative array tracking already-added indexes
#        (shared with select_user_mods' caller-side bookkeeping)
#   Globals: MC_VERSION (read/written via get_minecraft_version)
# Outputs:
#   side effect — appends to SUPPORTED_MODS/MOD_*/FINAL_MOD_INDEXES; may
#                 reset them and re-run check_mod_compatibility if the user
#                 switches MC version
#   return — 0 normal completion, 2 if MC version was switched and
#            select_user_mods was already re-invoked (caller must not
#            continue its own selection logic)
#   exit 1 — if the user chooses to stop the installer on an incompatible
#            custom mod
prompt_custom_mods() {
    local -n added_map_ref="$1"

    echo ""
    print_warning "Custom mods are untested in this splitscreen setup. Add at your own risk."
    local add_custom_choice="n"
    if ! read -r -p "Do you want to add custom mods from Modrinth/CurseForge? (y/N): " add_custom_choice; then
        print_warning "No input available for custom mod prompt, skipping custom mods."
        return 0
    fi

    case "${add_custom_choice,,}" in
        y|yes) ;;
        *) return 0 ;;
    esac

    print_info "Add one mod at a time, then press Enter."
    print_info "CurseForge: paste just the numeric project ID (example: 422301)"
    print_info "Modrinth: paste the mod URL or slug (example: sodium)"
    print_info "Custom mods must support your exact selected Minecraft version on Fabric."
    print_info "Type 'done' when finished."

    while true; do
        local custom_input=""
        if ! read -r -p "Custom mod (or 'done'): " custom_input; then
            print_info "Input ended. Continuing without additional custom mods."
            break
        fi

        case "${custom_input,,}" in
            done|d|q|quit|exit) break ;;
        esac

        if [[ -z "$custom_input" ]]; then
            continue
        fi

        local platform=""
        local mod_id=""
        if ! parse_custom_mod_input "$custom_input" platform mod_id; then
            print_warning "Could not parse that mod input. Use a supported URL or ID format."
            continue
        fi

        # #120 BYOK: resolve the CurseForge API key once, up-front, in THIS
        # parent shell (not a $() subshell) the first time a CurseForge mod is
        # added, so the capture-site get_curseforge_api_token calls below
        # inherit the exported key instead of re-prompting per mod. No-op after
        # the first call and for Modrinth-only sessions.
        if [[ "$platform" == "curseforge" ]]; then
            resolve_curseforge_api_token || true
        fi

        local existing_idx=""
        existing_idx=$(find_existing_mod_index "$platform" "$mod_id" || true)
        if [[ -n "$existing_idx" ]]; then
            if [[ -z "${added_map_ref[$existing_idx]:-}" ]]; then
                FINAL_MOD_INDEXES+=("$existing_idx")
                added_map_ref[$existing_idx]=1
                add_mod_dependencies "$existing_idx" added_map_ref
            fi
            print_info "Already available, added to selection: ${SUPPORTED_MODS[$existing_idx]}"
            continue
        fi

        local display_name=""
        display_name=$(get_custom_mod_display_name "$platform" "$mod_id")
        local pre_count=${#SUPPORTED_MODS[@]}
        local compatible=false

        print_progress "Checking compatibility for custom mod: $display_name"
        if [[ "$platform" == "modrinth" ]]; then
            if check_modrinth_mod_strict "$display_name" "$mod_id"; then
                compatible=true
            fi
        else
            if check_curseforge_mod_strict "$display_name" "$mod_id"; then
                compatible=true
            fi
        fi

        if [[ "$compatible" == true ]]; then
            local new_idx=$(( ${#SUPPORTED_MODS[@]} - 1 ))
            if (( new_idx >= pre_count )); then
                FINAL_MOD_INDEXES+=("$new_idx")
                added_map_ref[$new_idx]=1
                add_mod_dependencies "$new_idx" added_map_ref
                print_success "Added custom mod: ${SUPPORTED_MODS[$new_idx]}"
            fi
            continue
        fi

        print_warning "Custom mod '$display_name' is not compatible with Minecraft $MC_VERSION (Fabric)."
        local incompatible_choice=""
        if [[ "${CUSTOM_MOD_LAST_INCOMPAT_REASON:-}" == "no_fabric" ]]; then
            echo "Options:"
            echo "  1. Continue without this mod (recommended)"
            echo "  2. Stop installer"
            if ! read -r -p "Choose [1]: " incompatible_choice; then
                incompatible_choice="1"
            fi
            case "$incompatible_choice" in
                2)
                    print_error "Installer stopped by user due to incompatible custom mod."
                    exit 1
                    ;;
                *)
                    print_info "Skipping incompatible custom mod."
                    ;;
            esac
            continue
        fi

        echo "Options:"
        echo "  1. Continue without this mod (recommended)"
        echo "  2. Change to a supported Minecraft version (core mods + this mod)"
        echo "  3. Stop installer"
        if ! read -r -p "Choose [1]: " incompatible_choice; then
            incompatible_choice="1"
        fi

        case "$incompatible_choice" in
            2)
                print_info "Switching to Minecraft version selection constrained by core mods and '$display_name'..."
                EXTRA_REQUIRED_MOD_ID="$mod_id"
                EXTRA_REQUIRED_MOD_PLATFORM="$platform"
                EXTRA_REQUIRED_MOD_NAME="$display_name"

                # Pre-check constrained versions so we can avoid confusing fallback errors.
                local -a constrained_versions=()
                readarray -t constrained_versions <<< "$(get_supported_minecraft_versions 2>/dev/null || true)"
                local -a constrained_clean=()
                local ver
                for ver in "${constrained_versions[@]}"; do
                    if [[ -n "$ver" && "$ver" != "null" ]]; then
                        constrained_clean+=("$ver")
                    fi
                done
                if [[ ${#constrained_clean[@]} -eq 0 ]]; then
                    print_warning "No compatible Minecraft versions found for core mods + '$display_name'."
                    print_info "Continuing without this custom mod."
                    unset EXTRA_REQUIRED_MOD_ID EXTRA_REQUIRED_MOD_PLATFORM EXTRA_REQUIRED_MOD_NAME
                    continue
                fi

                # Re-run the version/core compatibility pipeline.
                if ! get_minecraft_version; then
                    print_warning "No compatible Minecraft versions found for core mods + '$display_name'."
                    print_info "Continuing without this custom mod."
                    unset EXTRA_REQUIRED_MOD_ID EXTRA_REQUIRED_MOD_PLATFORM EXTRA_REQUIRED_MOD_NAME
                    continue
                fi
                detect_java
                configure_polymc_defaults
                get_fabric_version
                get_lwjgl_version

                # Reset runtime mod arrays and recompute compatibility for the new MC version.
                SUPPORTED_MODS=()
                MOD_DESCRIPTIONS=()
                MOD_URLS=()
                MOD_IDS=()
                MOD_TYPES=()
                MOD_DEPENDENCIES=()
                FINAL_MOD_INDEXES=()
                MISSING_MODS=()

                check_mod_compatibility

                # Clear version filter now that we've selected and refreshed.
                unset EXTRA_REQUIRED_MOD_ID EXTRA_REQUIRED_MOD_PLATFORM EXTRA_REQUIRED_MOD_NAME

                print_info "Minecraft version updated. Restarting mod selection..."
                select_user_mods
                return 2
                ;;
            3)
                print_error "Installer stopped by user due to incompatible custom mod."
                exit 1
                ;;
            *)
                print_info "Skipping incompatible custom mod."
                ;;
        esac
    done
}

# _required_mods_summary: Join REQUIRED_SPLITSCREEN_MODS into a
# human-readable, comma-separated list for the "-1 = Install only required
# mods (...)" prompt line. Derives the summary from mods.conf's live
# required set instead of a hardcoded name, so it can't go stale again as
# required mods are added/removed (it used to always say "Controlify").
# Inputs:
#   Globals: REQUIRED_SPLITSCREEN_MODS[] (read)
# Outputs:
#   stdout — comma-separated mod names, e.g. "Controlify, Sodium, Lithium"
_required_mods_summary() {
    local out="" name
    for name in "${REQUIRED_SPLITSCREEN_MODS[@]}"; do
        out+="${out:+, }$name"
    done
    printf '%s\n' "$out"
}

# select_user_mods: Interactive mod selection with intelligent
# categorization. Separates required mods (auto-installed) from
# user-selectable ones, then drives the full dependency-resolution pipeline:
# mods.conf deps (resolve_conf_dependencies), API deps
# (resolve_all_dependencies), and custom mods (prompt_custom_mods). When
# mods.conf has no optional mods (every mod is "required"), the selection
# prompt is skipped entirely — an empty "available mods" list that still
# asked the user to choose was vestigial, not a real choice.
# Inputs:
#   Globals: SUPPORTED_MODS, REQUIRED_SPLITSCREEN_MODS[] (read); MC_VERSION
#            (read, may change via prompt_custom_mods' version-switch path)
# Outputs:
#   side effect — sets FINAL_MOD_INDEXES to the final install selection
#   exit 1 — if SUPPORTED_MODS is empty (no compatible mods for MC_VERSION)
select_user_mods() {
    print_header "🎯 MOD SELECTION"

    # Validate that we have compatible mods to present to the user
    local supported_count=0
    if [[ ${#SUPPORTED_MODS[@]} -gt 0 ]]; then
        supported_count=${#SUPPORTED_MODS[@]}
    fi
    if [[ $supported_count -eq 0 ]]; then
        print_error "No compatible mods found for Minecraft $MC_VERSION"
        exit 1
    fi

    # Build list of user-selectable mods by filtering out framework and required mods
    # Framework mods (Fabric API, etc.) are installed automatically as dependencies
    # Required mods (from mods.conf's "required|" lines) are always installed
    local user_mod_indexes=()    # Indexes of mods user can choose from
    local install_all_mods=false # Flag for "install all" option

    for i in "${!SUPPORTED_MODS[@]}"; do
        local skip=false

        # Skip required splitscreen mods (these are automatically installed)
        for req in "${REQUIRED_SPLITSCREEN_MODS[@]}"; do
            if [[ "${SUPPORTED_MODS[$i]}" == "$req"* ]]; then
                skip=true
                break
            fi
        done

        [[ "$skip" == false ]] && user_mod_indexes+=("$i")
    done

    local mod_selection=""
    if [[ ${#user_mod_indexes[@]} -eq 0 ]]; then
        # All of mods.conf is "required" right now (7/7) — there is nothing
        # optional to offer, so don't print an empty list and prompt anyway.
        install_all_mods=true
        print_info \
            "All $supported_count mods are required — nothing to select."
    else
        echo ""
        echo "The following mods are available for Minecraft $MC_VERSION:"
        echo ""

        # Display numbered list of user-selectable mods
        local counter=1
        for i in "${user_mod_indexes[@]}"; do
            echo "  $counter. ${SUPPORTED_MODS[$i]}"
            counter=$((counter + 1))
        done

        echo ""
        echo "Enter the numbers of the mods you want to install" \
            "(e.g., '1 3 5' or '1-5'):"
        echo "  0 = Install all available mods (default)"
        echo "  -1 = Install only required mods ($(_required_mods_summary))"
        echo ""

        read -p "Your choice [0]: " mod_selection

        # Process user selection
        if [[ -z "$mod_selection" || "$mod_selection" == "0" ]]; then
            install_all_mods=true
            print_info "Installing all available mods"
        elif [[ "$mod_selection" == "-1" ]]; then
            mod_selection=""
            print_info "Installing only required mods"
        else
            print_info "Installing selected mods"
        fi
    fi

    # Build final mod list including dependencies
    declare -A added
    
    if [[ "$install_all_mods" == true ]]; then
        for i in "${!SUPPORTED_MODS[@]}"; do
            FINAL_MOD_INDEXES+=("$i")
            added[$i]=1
        done
    else
        # Add selected mods
        if [[ -n "$mod_selection" ]]; then
            echo "Selected mods:"
            
            # SELECTION PROCESSING: Parse user input supporting individual numbers and ranges
            # Examples: "1 3 5", "1-5", "1 3-7 9"
            local expanded_selection=()
            
            # Parse each token in the selection
            for token in $mod_selection; do
                if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
                    # RANGE PARSING: Handle range format like "1-5"
                    local start_num=${token%-*}
                    local end_num=${token#*-}
                    
                    # Validate range bounds
                    local max_range=${#user_mod_indexes[@]}
                    if ((start_num >= 1 && end_num <= max_range && start_num <= end_num)); then
                        for ((range_num=start_num; range_num<=end_num; range_num++)); do
                            expanded_selection+=("$range_num")
                        done
                    else
                        print_warning "Invalid range: $token (valid range: 1-$max_range)"
                    fi
                elif [[ "$token" =~ ^[0-9]+$ ]]; then
                    # INDIVIDUAL NUMBER: Handle single number
                    local max_selection=${#user_mod_indexes[@]}
                    if ((token >= 1 && token <= max_selection)); then
                        expanded_selection+=("$token")
                    else
                        print_warning "Invalid selection: $token (valid range: 1-$max_selection)"
                    fi
                else
                    print_warning "Invalid format: $token (use numbers or ranges like 1-5)"
                fi
            done
            
            # Remove duplicates and sort
            expanded_selection=($(printf "%s\n" "${expanded_selection[@]}" | sort -nu))
            
            # Process the expanded selection
            for sel in "${expanded_selection[@]}"; do
                local idx=${user_mod_indexes[$((sel-1))]}
                echo "  ${SUPPORTED_MODS[$idx]}"
                FINAL_MOD_INDEXES+=("$idx")
                added[$idx]=1
            done
            
            # Add dependencies for selected mods
            for sel in "${expanded_selection[@]}"; do
                local idx=${user_mod_indexes[$((sel-1))]}
                add_mod_dependencies "$idx" added
            done
        fi
    fi
     # Ensure required splitscreen mods are always included
    for req in "${REQUIRED_SPLITSCREEN_MODS[@]}"; do
        for i in "${!SUPPORTED_MODS[@]}"; do
            if [[ "${SUPPORTED_MODS[$i]}" == "$req"* ]] && [[ -z "${added[$i]:-}" ]]; then
                FINAL_MOD_INDEXES+=("$i")
                added[$i]=1
                add_mod_dependencies "$i" added
            fi
        done
    done

    # Optional user-provided custom mods (validated against selected MC version).
    local custom_prompt_status=0
    prompt_custom_mods added || custom_prompt_status=$?
    if [[ $custom_prompt_status -eq 2 ]]; then
        return 0
    fi

    # Pass 1: resolve intra-list dependencies declared in mods.conf (fast, no API calls).
    # e.g. "Reese's Sodium Options" → auto-adds "Sodium" and "Sodium Options API".
    resolve_conf_dependencies

    # Pass 2: resolve any remaining dependencies via Modrinth/CurseForge APIs
    # (catches transitive deps of newly added mods and custom mods not in mods.conf).
    resolve_all_dependencies

    local final_count=0
    if [[ ${#FINAL_MOD_INDEXES[@]} -gt 0 ]]; then
        final_count=${#FINAL_MOD_INDEXES[@]}
    fi
    print_success "Final mod list prepared: $final_count mods selected"
}

# resolve_conf_dependencies: BFS over MOD_DEPS_BY_NAME (loaded from
# mods.conf). For every mod currently in FINAL_MOD_INDEXES, look up its
# declared deps and auto-add any not already included. Repeats until stable
# (handles chains like Reese's Sodium Options -> Sodium Options API ->
# Sodium in two passes). Called before resolve_all_dependencies() so the
# API pass doesn't need to re-do what mods.conf already expressed.
# Inputs:
#   Globals: MOD_DEPS_BY_NAME{}, SUPPORTED_MODS, FINAL_MOD_INDEXES (read)
# Outputs:
#   side effect — appends newly discovered indexes to FINAL_MOD_INDEXES
resolve_conf_dependencies() {
    # Nothing declared — skip quietly.
    if [[ ${#MOD_DEPS_BY_NAME[@]} -eq 0 ]]; then
        return 0
    fi

    # Build a fast lookup: index → already included
    local -A already_indexed=()
    for idx in "${FINAL_MOD_INDEXES[@]}"; do
        already_indexed["$idx"]=1
    done

    local changed=true
    while [[ "$changed" == true ]]; do
        changed=false
        local -a snapshot=("${FINAL_MOD_INDEXES[@]}")
        for idx in "${snapshot[@]}"; do
            local mod_name="${SUPPORTED_MODS[$idx]:-}"
            [[ -z "$mod_name" ]] && continue
            local dep_names="${MOD_DEPS_BY_NAME[$mod_name]:-}"
            [[ -z "$dep_names" ]] && continue

            IFS=',' read -ra deps <<< "$dep_names"
            for dep_name in "${deps[@]}"; do
                dep_name="${dep_name#"${dep_name%%[![:space:]]*}"}"
                dep_name="${dep_name%"${dep_name##*[![:space:]]}"}"
                [[ -z "$dep_name" ]] && continue

                for j in "${!SUPPORTED_MODS[@]}"; do
                    if [[ "${SUPPORTED_MODS[$j]}" == "$dep_name" ]] \
                       && [[ -z "${already_indexed[$j]:-}" ]]; then
                        FINAL_MOD_INDEXES+=("$j")
                        already_indexed["$j"]=1
                        print_info "Auto-adding '${dep_name}' (required by '${mod_name}')"
                        changed=true
                    fi
                done
            done
        done
    done
}

# add_mod_dependencies: Add a mod's already-resolved Modrinth/CurseForge
# dependency IDs (MOD_DEPENDENCIES[mod_idx]) to FINAL_MOD_INDEXES if not
# already selected. Does NOT fetch anything — deps must already be present
# in MOD_IDS (via check_modrinth_mod/check_curseforge_mod's original scan).
# Inputs:
#   $1 — mod_idx: index into MOD_DEPENDENCIES/MOD_IDS for the mod whose
#        dependencies should be added
#   $2 — nameref to an associative array tracking already-added indexes
#   Globals: MOD_DEPENDENCIES, MOD_IDS (read)
# Outputs:
#   side effect — appends to FINAL_MOD_INDEXES and the added-map nameref
add_mod_dependencies() {
    local mod_idx="$1"
    local -n added_ref="$2"
    
    # Add Modrinth dependencies
    local dep_string="${MOD_DEPENDENCIES[$mod_idx]}"
    if [[ -n "$dep_string" ]]; then
        read -a dep_arr <<< "$dep_string"
        for dep in "${dep_arr[@]}"; do
            if [[ -n "$dep" ]]; then
                for j in "${!MOD_IDS[@]}"; do
                    if [[ "${MOD_IDS[$j]}" == "$dep" ]] && [[ -z "${added_ref[$j]:-}" ]]; then
                        FINAL_MOD_INDEXES+=("$j")
                        added_ref[$j]=1
                    fi
                done
            fi
        done
    fi
}
