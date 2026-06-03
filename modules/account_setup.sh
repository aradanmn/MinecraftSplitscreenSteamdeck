#!/usr/bin/env bash
# =============================================================================
# @file        account_setup.sh
# @version     1.0.0
# @date        2026-06-03
# @author      Minecraft Splitscreen Steam Deck Project
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Microsoft account authentication during installation via OAuth 2.0
#   Device Code Flow. Allows users to log in on any device (phone, PC) by
#   visiting microsoft.com/devicelogin and entering a short code — no browser
#   required on the Steam Deck itself.
#
#   On success, writes a valid MSA entry to PrismLauncher's accounts.json so
#   Minecraft launches immediately without a manual login step.
#
#   The entire flow is pure bash + curl + jq (no extra dependencies).
#
# @dependencies
#   - utilities.sh  (print_* functions, prompt_yes_no)
#   - path_configuration.sh  (ACTIVE_DATA_DIR)
#   - version_info.sh  (MS_AUTH_CLIENT_ID)
#   - curl
#   - jq
#
# @exports
#   Functions:
#     - setup_microsoft_account : Main entry point (called from main_workflow.sh)
#
# @changelog
#   1.0.0 (2026-06-03) - Initial implementation: device code flow, token chain, accounts.json write
# =============================================================================

# =============================================================================
# MICROSOFT OAUTH ENDPOINTS
# =============================================================================

readonly _MS_TENANT="consumers"
readonly _MS_DEVICE_URL="https://login.microsoftonline.com/${_MS_TENANT}/oauth2/v2.0/devicecode"
readonly _MS_TOKEN_URL="https://login.microsoftonline.com/${_MS_TENANT}/oauth2/v2.0/token"
readonly _XBL_URL="https://user.auth.xboxlive.com/user/authenticate"
readonly _XSTS_URL="https://xsts.auth.xboxlive.com/xsts/authorize"
readonly _MC_AUTH_URL="https://api.minecraftservices.com/authentication/login_with_xbox"
readonly _MC_PROFILE_URL="https://api.minecraftservices.com/minecraft/profile"
readonly _MS_SCOPE="XboxLive.signin offline_access"

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

# @function _ms_device_code_flow
# @description Initiate device code flow and poll until user completes auth.
# @stdout      JSON: {"access_token":"...","refresh_token":"..."}
# @return      0 on success, 1 on timeout or error
_ms_device_code_flow() {
    local client_id="${MS_AUTH_CLIENT_ID:-}"
    if [[ -z "$client_id" ]]; then
        print_error "MS_AUTH_CLIENT_ID is not set — cannot authenticate"
        return 1
    fi

    # Step 1: Request device code
    local device_response
    device_response=$(curl -s --max-time 15 -X POST "$_MS_DEVICE_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${client_id}&scope=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$_MS_SCOPE" 2>/dev/null || echo "XboxLive.signin%20offline_access")" \
        2>/dev/null) || { print_error "Network error requesting device code"; return 1; }

    local user_code device_code interval expires_in
    user_code=$(echo "$device_response" | jq -r '.user_code // empty' 2>/dev/null)
    device_code=$(echo "$device_response" | jq -r '.device_code // empty' 2>/dev/null)
    interval=$(echo "$device_response" | jq -r '.interval // 5' 2>/dev/null)
    expires_in=$(echo "$device_response" | jq -r '.expires_in // 300' 2>/dev/null)

    if [[ -z "$user_code" || -z "$device_code" ]]; then
        print_error "Failed to get device code from Microsoft"
        print_info "   Response: $(echo "$device_response" | jq -r '.error_description // .error // "unknown"' 2>/dev/null)"
        return 1
    fi

    echo ""
    print_header "MICROSOFT ACCOUNT LOGIN"
    echo ""
    echo "  1. Open a browser on any device (phone, PC, etc.)"
    echo "  2. Visit: https://microsoft.com/devicelogin"
    echo "  3. Enter code: ${user_code}"
    echo ""
    print_info "Waiting for you to complete login (expires in ${expires_in}s)..."
    echo ""

    # Step 2: Poll for token
    local elapsed=0
    while [[ $elapsed -lt $expires_in ]]; do
        sleep "$interval"
        elapsed=$((elapsed + interval))

        local poll_response
        poll_response=$(curl -s --max-time 15 -X POST "$_MS_TOKEN_URL" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=${client_id}&device_code=${device_code}" \
            2>/dev/null) || continue

        local error
        error=$(echo "$poll_response" | jq -r '.error // empty' 2>/dev/null)

        if [[ -z "$error" ]]; then
            # Success — return the token JSON
            echo "$poll_response" | jq '{access_token: .access_token, refresh_token: .refresh_token}' 2>/dev/null
            return 0
        fi

        case "$error" in
            authorization_pending) continue ;;
            slow_down) interval=$((interval + 5)); continue ;;
            authorization_declined) print_error "Login was declined"; return 1 ;;
            expired_token) print_error "Login code expired"; return 1 ;;
            *) print_error "Auth error: $error"; return 1 ;;
        esac
    done

    print_error "Login timed out (${expires_in}s)"
    return 1
}

# @function _ms_to_xbl
# @description Exchange MS access token for Xbox Live token.
# @param $1 - ms_access_token
# @stdout JSON with xbl_token and user_hash
_ms_to_xbl() {
    local ms_token="$1"
    local response
    response=$(curl -s --max-time 15 -X POST "$_XBL_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{
            \"Properties\": {
                \"AuthMethod\": \"RPS\",
                \"SiteName\": \"user.auth.xboxlive.com\",
                \"RpsTicket\": \"d=${ms_token}\"
            },
            \"RelyingParty\": \"http://auth.xboxlive.com\",
            \"TokenType\": \"JWT\"
        }" 2>/dev/null) || return 1

    local xbl_token user_hash
    xbl_token=$(echo "$response" | jq -r '.Token // empty' 2>/dev/null)
    user_hash=$(echo "$response" | jq -r '.DisplayClaims.xui[0].uhs // empty' 2>/dev/null)

    if [[ -z "$xbl_token" ]]; then
        print_error "Failed to get Xbox Live token"
        return 1
    fi

    echo "{\"xbl_token\": \"${xbl_token}\", \"user_hash\": \"${user_hash}\"}"
}

# @function _xbl_to_xsts
# @description Exchange XBL token for XSTS token (Minecraft service audience).
# @param $1 - xbl_token
# @stdout XSTS token string
_xbl_to_xsts() {
    local xbl_token="$1"
    local response
    response=$(curl -s --max-time 15 -X POST "$_XSTS_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{
            \"Properties\": {
                \"SandboxId\": \"RETAIL\",
                \"UserTokens\": [\"${xbl_token}\"]
            },
            \"RelyingParty\": \"rp://api.minecraftservices.com/\",
            \"TokenType\": \"JWT\"
        }" 2>/dev/null) || return 1

    local xsts_token
    xsts_token=$(echo "$response" | jq -r '.Token // empty' 2>/dev/null)

    if [[ -z "$xsts_token" ]]; then
        local err_code
        err_code=$(echo "$response" | jq -r '.XErr // empty' 2>/dev/null)
        case "$err_code" in
            2148916233) print_error "Microsoft account has no Xbox profile. Visit xbox.com to create one." ;;
            2148916235) print_error "Xbox Live is not available in your region." ;;
            2148916238) print_error "Child accounts require parental consent." ;;
            *) print_error "XSTS auth failed (XErr: ${err_code:-unknown})" ;;
        esac
        return 1
    fi

    echo "$xsts_token"
}

# @function _xsts_to_minecraft
# @description Exchange XSTS token + user hash for Minecraft access token.
# @param $1 - xsts_token
# @param $2 - user_hash
# @stdout Minecraft access token string
_xsts_to_minecraft() {
    local xsts_token="$1"
    local user_hash="$2"
    local response
    response=$(curl -s --max-time 15 -X POST "$_MC_AUTH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"identityToken\": \"XBL3.0 x=${user_hash};${xsts_token}\"}" \
        2>/dev/null) || return 1

    local mc_token
    mc_token=$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null)

    if [[ -z "$mc_token" ]]; then
        print_error "Failed to get Minecraft access token"
        return 1
    fi

    echo "$mc_token"
}

# @function _get_minecraft_profile
# @description Fetch Minecraft profile (username + UUID) from access token.
# @param $1 - mc_access_token
# @stdout JSON: {"name":"...","id":"..."}
_get_minecraft_profile() {
    local mc_token="$1"
    local response
    response=$(curl -s --max-time 15 -H "Authorization: Bearer ${mc_token}" \
        "$_MC_PROFILE_URL" 2>/dev/null) || return 1

    local username uuid
    username=$(echo "$response" | jq -r '.name // empty' 2>/dev/null)
    uuid=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)

    if [[ -z "$username" || -z "$uuid" ]]; then
        # Account exists but may not own Minecraft Java Edition
        local err
        err=$(echo "$response" | jq -r '.errorMessage // .error // "unknown"' 2>/dev/null)
        print_error "Could not retrieve Minecraft profile: $err"
        print_info "   Ensure this Microsoft account has purchased Minecraft Java Edition."
        return 1
    fi

    echo "{\"name\": \"${username}\", \"id\": \"${uuid}\"}"
}

# @function _write_prism_account
# @description Write or merge MSA entry into PrismLauncher's accounts.json.
# @param $1 - accounts_path: path to PrismLauncher accounts.json
# @param $2 - mc_token: Minecraft access token
# @param $3 - ms_token: Microsoft access token
# @param $4 - refresh_token: Microsoft refresh token
# @param $5 - username: Minecraft IGN
# @param $6 - uuid: Minecraft UUID (no dashes)
_write_prism_account() {
    local accounts_path="$1"
    local mc_token="$2"
    local ms_token="$3"
    local refresh_token="$4"
    local username="$5"
    local uuid="$6"
    local client_id="${MS_AUTH_CLIENT_ID:-}"
    local validity
    validity=$(date -d "+3600 seconds" +%s 2>/dev/null || date -v +3600S +%s 2>/dev/null || echo "0")

    local new_entry
    new_entry=$(jq -n \
        --arg mc_token "$mc_token" \
        --arg ms_token "$ms_token" \
        --arg refresh_token "$refresh_token" \
        --arg username "$username" \
        --arg uuid "$uuid" \
        --arg client_id "$client_id" \
        --argjson validity "$validity" \
        '{
            "active": true,
            "type": "MSA",
            "userType": "msa",
            "ygg": {
                "token": $mc_token,
                "userName": $username,
                "profileName": $username
            },
            "profile": {
                "id": $uuid,
                "name": $username,
                "capes": [],
                "skin": {"id": "", "url": "", "variant": "CLASSIC"}
            },
            "msaToken": {
                "extra": {"client_id": $client_id, "redirect_uri": "https://login.microsoftonline.com/common/oauth2/nativeclient"},
                "token": $ms_token,
                "refresh_token": $refresh_token,
                "validity": $validity
            }
        }' 2>/dev/null) || { print_error "Failed to build account JSON"; return 1; }

    # Create or merge accounts.json
    if [[ ! -f "$accounts_path" ]]; then
        jq -n --argjson entry "$new_entry" \
            '{"accounts": [$entry], "formatVersion": 3}' > "$accounts_path" 2>/dev/null \
            || { print_error "Failed to create accounts.json"; return 1; }
    else
        local tmp
        tmp=$(mktemp) || return 1
        # Remove any existing MSA entry for this username, then prepend new one
        if jq --argjson entry "$new_entry" --arg name "$username" \
            '.accounts = [$entry] + (.accounts | map(select(.profile.name != $name))) |
             .formatVersion = 3' \
            "$accounts_path" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$accounts_path"
        else
            rm -f "$tmp"
            print_error "Failed to merge accounts.json"
            return 1
        fi
    fi

    print_success "Microsoft account saved: ${username}"
    return 0
}

# =============================================================================
# PUBLIC ENTRY POINT
# =============================================================================

# @function setup_microsoft_account
# @description Interactive Microsoft account setup during installation.
#              Prompts the user, runs device code flow, and writes the account
#              to PrismLauncher's accounts.json. Safe to skip.
# @global ACTIVE_DATA_DIR - path to PrismLauncher data directory
# @return 0 always (failure is non-fatal; user can log in manually later)
setup_microsoft_account() {
    print_header "MICROSOFT ACCOUNT SETUP (optional)"
    echo ""
    echo "  Log in now to skip the manual login step after installation."
    echo "  You will be shown a code to enter on any device with a browser."
    echo ""

    prompt_yes_no "Set up Microsoft account now?" "y"
    if [[ "$PROMPT_REPLY" != "y" && "$PROMPT_REPLY" != "yes" ]]; then
        print_info "Skipping Microsoft account setup — log in via PrismLauncher after install."
        return 0
    fi

    local accounts_path="${ACTIVE_DATA_DIR}/accounts.json"

    # Run device code flow
    local ms_tokens
    if ! ms_tokens=$(_ms_device_code_flow); then
        print_warning "Microsoft authentication failed — skipping account setup."
        print_info "   → Log in manually: open PrismLauncher → Accounts → Add Microsoft"
        return 0
    fi

    local ms_access_token refresh_token
    ms_access_token=$(echo "$ms_tokens" | jq -r '.access_token' 2>/dev/null)
    refresh_token=$(echo "$ms_tokens" | jq -r '.refresh_token' 2>/dev/null)

    print_progress "Exchanging tokens with Xbox Live..."

    # XBL
    local xbl_data xbl_token user_hash
    if ! xbl_data=$(_ms_to_xbl "$ms_access_token"); then
        print_warning "Xbox Live token exchange failed — skipping account setup."
        print_info "   → Log in manually via PrismLauncher after install."
        return 0
    fi
    xbl_token=$(echo "$xbl_data" | jq -r '.xbl_token' 2>/dev/null)
    user_hash=$(echo "$xbl_data" | jq -r '.user_hash' 2>/dev/null)

    # XSTS
    local xsts_token
    if ! xsts_token=$(_xbl_to_xsts "$xbl_token"); then
        print_warning "XSTS token exchange failed — skipping account setup."
        print_info "   → Log in manually via PrismLauncher after install."
        return 0
    fi

    # Minecraft token
    local mc_token
    if ! mc_token=$(_xsts_to_minecraft "$xsts_token" "$user_hash"); then
        print_warning "Minecraft token exchange failed — skipping account setup."
        print_info "   → Log in manually via PrismLauncher after install."
        return 0
    fi

    print_progress "Fetching Minecraft profile..."

    # Profile
    local profile_json username uuid
    if ! profile_json=$(_get_minecraft_profile "$mc_token"); then
        print_warning "Could not fetch Minecraft profile — skipping account setup."
        print_info "   → Log in manually via PrismLauncher after install."
        return 0
    fi
    username=$(echo "$profile_json" | jq -r '.name' 2>/dev/null)
    uuid=$(echo "$profile_json" | jq -r '.id' 2>/dev/null)

    # Write to PrismLauncher
    if ! _write_prism_account "$accounts_path" "$mc_token" "$ms_access_token" \
            "$refresh_token" "$username" "$uuid"; then
        print_warning "Could not write account to PrismLauncher — skipping."
        print_info "   → Log in manually via PrismLauncher after install."
        return 0
    fi

    print_success "Microsoft account configured successfully: ${username}"
    print_info "   → PrismLauncher will use this account automatically on launch."
    return 0
}
