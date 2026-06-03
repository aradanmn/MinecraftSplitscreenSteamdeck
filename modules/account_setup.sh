#!/usr/bin/env bash
#
# @file account_setup.sh
# @version 1.0.0
# @date 2026-06-03
# @author aradanmn
# @license MIT
# @repository https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Microsoft OAuth 2.0 device-code flow for Minecraft Java Edition account
#   authentication. Walks the full chain: device code → MS token → Xbox Live →
#   XSTS → Minecraft token → entitlement check → profile fetch → accounts.json.
#
#   Uses PrismLauncher's public OAuth client ID — no Azure App Registration is
#   required. The /consumers/ endpoint is used throughout; /common/ returns
#   AAD-flavoured tokens that Xbox Live rejects.
#
#   The resulting MSA account is merged into PrismLauncher's accounts.json
#   alongside the existing P1-P4 offline splitscreen accounts.
#
# @dependencies
#   - curl     (HTTP requests)
#   - jq       (JSON parsing and construction)
#   - utilities.sh        (print_*, prompt_yes_no)
#   - path_configuration.sh (CREATION_DATA_DIR)
#
# @exports
#   - run_account_setup()        Main entry point (called from main_workflow.sh)
#   - check_microsoft_account()  Returns 0 if an MSA account already exists

# Guard against double-sourcing
[[ -n "${_ACCOUNT_SETUP_LOADED:-}" ]] && return 0
readonly _ACCOUNT_SETUP_LOADED=1

# PrismLauncher's registered public OAuth client ID.
# Using this ID means we inherit PrismLauncher's trusted app relationship with
# Microsoft — no Azure registration needed for this open-source project.
readonly _MSA_CLIENT_ID="c36a9fb6-4f2a-41ff-90bd-ae7cc92031eb"

# Must use /consumers/ (personal Microsoft accounts).
# /common/ can return AAD tokens that Xbox Live rejects with HTTP 400.
readonly _MS_DEVICECODE_URL="https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode"
readonly _MS_TOKEN_URL="https://login.microsoftonline.com/consumers/oauth2/v2.0/token"
readonly _XBL_AUTH_URL="https://user.auth.xboxlive.com/user/authenticate"
readonly _XSTS_AUTH_URL="https://xsts.auth.xboxlive.com/xsts/authorize"
readonly _MC_LOGIN_URL="https://api.minecraftservices.com/authentication/login_with_xbox"
readonly _MC_ENTITLEMENT_URL="https://api.minecraftservices.com/entitlements/mcstore"
readonly _MC_PROFILE_URL="https://api.minecraftservices.com/minecraft/profile"

# =============================================================================
# PUBLIC: check_microsoft_account
# Returns 0 if at least one MSA account already exists in accounts.json.
# =============================================================================
check_microsoft_account() {
    local accounts_path="${CREATION_DATA_DIR}/accounts.json"
    [[ -f "$accounts_path" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local count
    count=$(jq '[.accounts[] | select(.type == "MSA")] | length' "$accounts_path" 2>/dev/null || echo 0)
    [[ "${count:-0}" -gt 0 ]]
}

# =============================================================================
# PRIVATE: Step 1 — Request device code
# Sets module-level vars: _MSA_DEVICE_CODE, _MSA_USER_CODE,
#   _MSA_VERIFICATION_URI, _MSA_EXPIRES_IN, _MSA_POLL_INTERVAL
# =============================================================================
_request_device_code() {
    local response
    response=$(curl -s --fail-with-body -X POST "$_MS_DEVICECODE_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${_MSA_CLIENT_ID}&scope=XboxLive.signin%20offline_access") || {
        print_error "❌ Could not reach Microsoft authentication servers."
        return 1
    }

    # Validate we got a device_code back
    if ! jq -e '.device_code' <<< "$response" >/dev/null 2>&1; then
        local err_desc
        err_desc=$(jq -r '.error_description // .error // "unknown error"' <<< "$response" 2>/dev/null)
        print_error "❌ Device code request failed: ${err_desc}"
        return 1
    fi

    _MSA_DEVICE_CODE=$(jq -r '.device_code' <<< "$response")
    _MSA_USER_CODE=$(jq -r '.user_code' <<< "$response")
    _MSA_VERIFICATION_URI=$(jq -r '.verification_uri' <<< "$response")
    _MSA_EXPIRES_IN=$(jq -r '.expires_in' <<< "$response")
    _MSA_POLL_INTERVAL=$(jq -r '.interval // 5' <<< "$response")
}

# =============================================================================
# PRIVATE: Step 2 — Poll for Microsoft access token
# Args: <device_code> <expires_in_seconds> <poll_interval_seconds>
# Sets: _MSA_ACCESS_TOKEN, _MSA_REFRESH_TOKEN, _MSA_TOKEN_EXPIRES_IN
# Returns: 0=success 1=error/timeout 2=access_denied
# =============================================================================
_poll_ms_token() {
    local device_code="$1"
    local expires_in="$2"
    local interval="${3:-5}"

    local deadline=$(( $(date +%s) + expires_in ))
    local current_interval="$interval"
    local response error elapsed last_dot=0

    while [[ $(date +%s) -lt $deadline ]]; do
        sleep "$current_interval"

        response=$(curl -s -X POST "$_MS_TOKEN_URL" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=${_MSA_CLIENT_ID}&device_code=${device_code}") || continue

        error=$(jq -r '.error // empty' <<< "$response" 2>/dev/null)

        case "$error" in
            authorization_pending)
                # Print a dot every ~15s so the user knows we're alive
                elapsed=$(date +%s)
                if (( elapsed - last_dot >= 15 )); then
                    printf '.' >&2
                    last_dot=$elapsed
                fi
                continue
                ;;
            slow_down)
                current_interval=$(( current_interval + 5 ))
                continue
                ;;
            expired_token)
                echo "" >&2
                print_error "❌ Authentication code expired. Please run the installer again to get a new code."
                return 1
                ;;
            access_denied)
                echo "" >&2
                print_error "❌ Authentication was cancelled or denied."
                return 2
                ;;
            "")
                echo "" >&2
                _MSA_ACCESS_TOKEN=$(jq -r '.access_token' <<< "$response")
                _MSA_REFRESH_TOKEN=$(jq -r '.refresh_token // ""' <<< "$response")
                _MSA_TOKEN_EXPIRES_IN=$(jq -r '.expires_in // 3600' <<< "$response")
                return 0
                ;;
            *)
                echo "" >&2
                local err_desc
                err_desc=$(jq -r '.error_description // .error' <<< "$response" 2>/dev/null)
                print_error "❌ Token error: ${err_desc}"
                return 1
                ;;
        esac
    done

    echo "" >&2
    print_error "❌ Timed out waiting for authentication."
    return 1
}

# =============================================================================
# PRIVATE: Step 3 — Xbox Live authentication
# Args: <ms_access_token>
# Sets: _XBL_TOKEN, _XBL_UHS
# =============================================================================
_auth_xbox_live() {
    local ms_token="$1"

    local body
    body=$(jq -n --arg tok "d=${ms_token}" '{
        Properties: {
            AuthMethod: "RPS",
            SiteName:   "user.auth.xboxlive.com",
            RpsTicket:  $tok
        },
        RelyingParty: "http://auth.xboxlive.com",
        TokenType: "JWT"
    }')

    local response
    response=$(curl -s --fail-with-body -X POST "$_XBL_AUTH_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$body") || {
        print_error "❌ Xbox Live authentication request failed."
        return 1
    }

    _XBL_TOKEN=$(jq -r '.Token // empty' <<< "$response")
    _XBL_UHS=$(jq -r '.DisplayClaims.xui[0].uhs // empty' <<< "$response")

    if [[ -z "$_XBL_TOKEN" ]]; then
        local err
        err=$(jq -r '.Message // .message // "unknown"' <<< "$response" 2>/dev/null)
        print_error "❌ Xbox Live authentication failed: ${err}"
        return 1
    fi
}

# =============================================================================
# PRIVATE: Step 4 — XSTS token
# Args: <xbl_token>
# Sets: _XSTS_TOKEN, _XSTS_UHS
# Returns: 0=ok 1=generic 2=no Xbox account 3=child account 4=region blocked
# =============================================================================
_auth_xsts() {
    local xbl_token="$1"

    local body
    body=$(jq -n --arg tok "$xbl_token" '{
        Properties: {
            SandboxId:  "RETAIL",
            UserTokens: [$tok]
        },
        RelyingParty: "rp://api.minecraftservices.com/",
        TokenType: "JWT"
    }')

    local response http_code
    response=$(curl -s -w $'\n%{http_code}' -X POST "$_XSTS_AUTH_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$body")
    http_code=$(tail -1 <<< "$response")
    response=$(sed '$d' <<< "$response")

    if [[ "$http_code" != "200" ]]; then
        local xerr
        xerr=$(jq -r '.XErr // empty' <<< "$response" 2>/dev/null)
        case "$xerr" in
            2148916233)
                print_error "❌ No Xbox profile found for this Microsoft account."
                print_info "   → Visit https://xbox.com, create an Xbox profile, then re-run setup."
                return 2
                ;;
            2148916238)
                print_error "❌ This Microsoft account is a child account."
                print_info "   → Parental consent or an adult account is required to play Minecraft."
                return 3
                ;;
            2148916235|2148916236|2148916237)
                print_error "❌ Xbox Live is not available in your region (XErr ${xerr})."
                return 4
                ;;
            *)
                print_error "❌ XSTS authentication failed (HTTP ${http_code}, XErr: ${xerr:-none})."
                return 1
                ;;
        esac
    fi

    _XSTS_TOKEN=$(jq -r '.Token // empty' <<< "$response")
    _XSTS_UHS=$(jq -r '.DisplayClaims.xui[0].uhs // empty' <<< "$response")

    if [[ -z "$_XSTS_TOKEN" ]]; then
        print_error "❌ XSTS response missing Token field."
        return 1
    fi
}

# =============================================================================
# PRIVATE: Step 5 — Minecraft authentication
# Args: <uhs> <xsts_token>
# Sets: _MC_ACCESS_TOKEN, _MC_TOKEN_EXPIRES_IN
# The identityToken format is literal:
#   "XBL:uhs=<uhs> XBL3.0 x=<uhs>;<xsts_token>"
# (space before XBL3.0; semicolon before xsts_token; uhs appears twice)
# =============================================================================
_auth_minecraft() {
    local uhs="$1"
    local xsts_token="$2"

    local identity_token="XBL:uhs=${uhs} XBL3.0 x=${uhs};${xsts_token}"
    local body
    body=$(jq -n --arg it "$identity_token" '{"identityToken": $it}')

    local response
    response=$(curl -s --fail-with-body -X POST "$_MC_LOGIN_URL" \
        -H "Content-Type: application/json" \
        -d "$body") || {
        print_error "❌ Minecraft authentication request failed."
        return 1
    }

    _MC_ACCESS_TOKEN=$(jq -r '.access_token // empty' <<< "$response")
    _MC_TOKEN_EXPIRES_IN=$(jq -r '.expires_in // 86400' <<< "$response")

    if [[ -z "$_MC_ACCESS_TOKEN" ]]; then
        local err
        err=$(jq -r '.error // .errorMessage // "unknown"' <<< "$response" 2>/dev/null)
        print_error "❌ Minecraft authentication failed: ${err}"
        return 1
    fi
}

# =============================================================================
# PRIVATE: Step 6 — Entitlement check
# Args: <minecraft_access_token>
# Returns 0 if Minecraft Java Edition is owned (or Game Pass).
# Non-fatal: caller shows a warning but continues on failure.
# =============================================================================
_check_entitlement() {
    local mc_token="$1"
    local response
    response=$(curl -s "$_MC_ENTITLEMENT_URL" \
        -H "Authorization: Bearer ${mc_token}") || return 1

    local has_game
    has_game=$(jq '[.items[]? | .name | test("minecraft"; "i")] | any' \
        <<< "$response" 2>/dev/null)
    [[ "$has_game" == "true" ]]
}

# =============================================================================
# PRIVATE: Step 7 — Minecraft profile
# Args: <minecraft_access_token>
# Sets: _MC_PROFILE_ID, _MC_PROFILE_NAME
# =============================================================================
_get_mc_profile() {
    local mc_token="$1"
    local response
    response=$(curl -s --fail-with-body "$_MC_PROFILE_URL" \
        -H "Authorization: Bearer ${mc_token}") || {
        print_error "❌ Failed to fetch Minecraft profile."
        return 1
    }

    _MC_PROFILE_ID=$(jq -r '.id // empty' <<< "$response")
    _MC_PROFILE_NAME=$(jq -r '.name // empty' <<< "$response")

    if [[ -z "$_MC_PROFILE_ID" || -z "$_MC_PROFILE_NAME" ]]; then
        local err
        err=$(jq -r '.error // .errorMessage // "no profile found"' <<< "$response" 2>/dev/null)
        print_error "❌ Minecraft profile missing: ${err}"
        print_info "   → Ensure your account has a Java Edition profile at minecraft.net"
        return 1
    fi
}

# =============================================================================
# PRIVATE: Step 8 — Write account to PrismLauncher's accounts.json
# Removes any existing MSA account, sets P1-P4 offline accounts to
# active=false, and inserts the new MSA account as active=true.
# =============================================================================
_write_msa_to_accounts_json() {
    local accounts_path="${CREATION_DATA_DIR}/accounts.json"
    local now
    now=$(date +%s)

    # Random UUID-style client token
    local client_token
    if command -v uuidgen >/dev/null 2>&1; then
        client_token=$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        client_token=$(tr -d '-' < /proc/sys/kernel/random/uuid)
    else
        client_token=$(printf '%08x%08x%08x%08x' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM")
    fi

    local ms_expiry=$(( now + _MSA_TOKEN_EXPIRES_IN ))
    local mc_expiry=$(( now + _MC_TOKEN_EXPIRES_IN ))

    # Build the full MSA account object PrismLauncher expects (formatVersion 3)
    local new_account
    new_account=$(jq -n \
        --arg  profile_id    "$_MC_PROFILE_ID" \
        --arg  profile_name  "$_MC_PROFILE_NAME" \
        --arg  mc_token      "$_MC_ACCESS_TOKEN" \
        --arg  client_token  "$client_token" \
        --arg  ms_token      "$_MSA_ACCESS_TOKEN" \
        --arg  refresh_token "$_MSA_REFRESH_TOKEN" \
        --arg  xbl_token     "$_XBL_TOKEN" \
        --arg  xbl_uhs       "$_XBL_UHS" \
        --arg  xsts_token    "$_XSTS_TOKEN" \
        --argjson now         "$now" \
        --argjson ms_expiry   "$ms_expiry" \
        --argjson mc_expiry   "$mc_expiry" \
        '{
            active: true,
            type:   "MSA",
            profile: {
                id:    $profile_id,
                name:  $profile_name,
                capes: [],
                skin:  {id: "", url: "", variant: ""}
            },
            ygg: {
                token:  $mc_token,
                iat:    $now,
                expiry: $mc_expiry,
                extra:  {clientToken: $client_token, userName: $profile_name}
            },
            msa: {
                token:         $ms_token,
                refresh_token: $refresh_token,
                iat:           $now,
                expiry:        $ms_expiry,
                extra:         {userName: $profile_name}
            },
            xbl: {
                token: $xbl_token,
                iat:   $now,
                extra: {userName: $xbl_uhs}
            },
            xsts: {
                token: $xsts_token,
                iat:   $now,
                extra: {userName: ""}
            },
            entitlement: {
                canPlayMinecraft: true,
                ownsMinecraft:    true
            }
        }') || {
        print_error "❌ Failed to build account JSON."
        return 1
    }

    local tmp
    tmp=$(mktemp)

    if [[ -f "$accounts_path" ]]; then
        # Remove any existing MSA accounts; mark all others inactive; append new MSA
        jq --argjson msa "$new_account" '
            .accounts = (
                [.accounts[] | select(.type != "MSA") | .active = false]
                + [$msa]
            )
        ' "$accounts_path" > "$tmp" && mv "$tmp" "$accounts_path" || {
            rm -f "$tmp"
            print_error "❌ Failed to write accounts.json."
            return 1
        }
    else
        # No existing accounts.json — create one from scratch
        jq -n \
            --argjson msa "$new_account" \
            '{"accounts": [$msa], "formatVersion": 3}' > "$accounts_path" || {
            rm -f "$tmp"
            print_error "❌ Failed to create accounts.json."
            return 1
        }
        rm -f "$tmp"
    fi
}

# =============================================================================
# PRIVATE: Full OAuth flow (Steps 1-8)
# =============================================================================
_do_microsoft_oauth() {
    # Step 1: device code
    print_progress "Contacting Microsoft authentication servers..."
    _request_device_code || return 1

    # Display sign-in instructions prominently
    print_header "Microsoft Account Sign-In"
    echo ""
    print_info "Open this URL on any device (phone, tablet, or another PC):"
    echo ""
    echo "    https://microsoft.com/devicelogin"
    echo ""
    print_info "Then enter this code when prompted:"
    echo ""
    echo "    ╔══════════════╗"
    echo "    ║  ${_MSA_USER_CODE}  ║"
    echo "    ╚══════════════╝"
    echo ""
    print_info "Waiting for sign-in (code expires in ${_MSA_EXPIRES_IN}s)..."
    printf '    '

    # Step 2: poll for token
    _poll_ms_token "$_MSA_DEVICE_CODE" "$_MSA_EXPIRES_IN" "$_MSA_POLL_INTERVAL" || return $?

    print_success "✅ Microsoft sign-in confirmed."

    # Step 3: Xbox Live
    print_progress "Authenticating with Xbox Live..."
    _auth_xbox_live "$_MSA_ACCESS_TOKEN" || return 1

    # Step 4: XSTS
    print_progress "Requesting XSTS security token..."
    _auth_xsts "$_XBL_TOKEN" || return $?

    # Step 5: Minecraft token
    print_progress "Obtaining Minecraft access token..."
    _auth_minecraft "$_XSTS_UHS" "$_XSTS_TOKEN" || return 1

    # Step 6: entitlement (non-fatal)
    print_progress "Verifying Minecraft ownership..."
    if ! _check_entitlement "$_MC_ACCESS_TOKEN"; then
        print_warning "⚠️  Minecraft ownership could not be confirmed via entitlement API."
        print_info "   → Game Pass subscriptions may show this — the account will still work."
        print_info "   → If you don't own Minecraft, launching will fail at runtime."
    fi

    # Step 7: profile
    print_progress "Fetching Minecraft profile..."
    _get_mc_profile "$_MC_ACCESS_TOKEN" || return 1

    # Step 8: write accounts.json
    print_progress "Saving account to PrismLauncher..."
    _write_msa_to_accounts_json || return 1

    print_success "✅ Microsoft account configured successfully!"
    print_info "   → Signed in as: ${_MC_PROFILE_NAME}"
    print_info "   → Account written to PrismLauncher's accounts.json"
    print_info "   → P1-P4 offline profiles preserved for splitscreen identity"
}

# =============================================================================
# PUBLIC: run_account_setup
# Called from main_workflow.sh after offline accounts are merged.
# =============================================================================
run_account_setup() {
    if ! command -v jq >/dev/null 2>&1; then
        print_warning "⚠️  jq not found — Microsoft account setup skipped."
        print_info "   → Install jq and re-run the installer, or add your account in PrismLauncher."
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        print_warning "⚠️  curl not found — Microsoft account setup skipped."
        return 0
    fi

    # --- Already authenticated? ---
    if check_microsoft_account; then
        local existing_name
        existing_name=$(jq -r '
            [.accounts[] | select(.type == "MSA")][0].profile.name // "unknown"
        ' "${CREATION_DATA_DIR}/accounts.json" 2>/dev/null)

        print_success "✅ Microsoft account already configured: ${existing_name}"

        if ! prompt_yes_no "Authenticate a different Microsoft account?" "n"; then
            return 0
        fi
    fi

    # --- Prompt to set up now ---
    print_header "Microsoft Account Setup"
    print_info "A Microsoft account with Minecraft Java Edition is required to play."
    print_info "You can sign in now, or add your account manually in PrismLauncher later."
    echo ""

    if ! prompt_yes_no "Set up Microsoft account now?" "y"; then
        print_warning "⚠️  Microsoft account setup skipped."
        print_info "   → Open PrismLauncher after installation: Accounts → Add Microsoft."
        return 0
    fi

    # --- Run the OAuth flow (failure is non-fatal; installer continues) ---
    if ! _do_microsoft_oauth; then
        echo ""
        print_warning "⚠️  Microsoft account setup did not complete."
        print_info "   → You can still sign in manually inside PrismLauncher."
        print_info "   → Splitscreen offline mode (P1-P4) will work without this account."
        return 0
    fi
}
