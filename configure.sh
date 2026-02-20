#!/usr/bin/env bash
set -euo pipefail

#######
# THIS SCRIPT IS WRITTEN WITH AI.
# AS SUCH, IT MIGHT NOT WORK AS INTENDED.
# USE AT YOUR OWN RISK.
#######

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Source environment ─────────────────────────────────────────
set -a
source .env
source .secrets
set +a

# ─── Global variables (set by configure functions, used across them) ──
SONARR_API_KEY=""
RADARR_API_KEY=""
JELLYFIN_API_KEY=""

# ─── Service URLs (accessible from host) ───────────────────────
QB_URL="http://localhost:${QBITTORRENT_WEBUI_PORT}"
SONARR_URL="http://localhost:${SONARR_PORT}"
RADARR_URL="http://localhost:${RADARR_PORT}"
PROWLARR_URL="http://localhost:${PROWLARR_PORT}"
JELLYFIN_URL="http://localhost:${JELLYFIN_PORT}"
SEERR_URL="http://localhost:${SEERR_PORT}"
JELLYSTAT_URL="http://localhost:${JELLYSTAT_PORT}"

# ─── Output helpers ─────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
err()     { echo -e "${RED}[-]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ─── Gather credentials ────────────────────────────────────────
section "Gathering credentials"

read -p "Main username (default: ewancoder): " MAIN_USER
MAIN_USER="${MAIN_USER:-ewancoder}"

read -p "Kinozal username: " KINOZAL_USER
read -sp "Kinozal password: " KINOZAL_PASS; echo
read -p "RuTracker username: " RUTRACKER_USER
read -sp "RuTracker password: " RUTRACKER_PASS; echo
read -p "Jellyfin login disclaimer text: " JELLYFIN_DISCLAIMER

# ─── Helper functions ───────────────────────────────────────────
wait_for_service() {
    local name="$1" url="$2" max_wait="${3:-180}"
    info "Waiting for $name..."
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
        if [[ "$code" =~ ^(200|301|302|401|400|403)$ ]]; then
            log "$name is ready"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    err "$name did not become ready within ${max_wait}s"
    return 1
}

wait_for_file() {
    local path="$1" max_wait="${2:-120}"
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        [ -f "$path" ] && return 0
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

get_api_key() {
    local config_path="$1"
    grep -oP '<ApiKey>\K[^<]+' "$config_path"
}

# ═══════════════════════════════════════════════════════════════
#  qBitTorrent
# ═══════════════════════════════════════════════════════════════
configure_qbittorrent() {
    section "Configuring qBitTorrent"

    wait_for_service "qBitTorrent" "$QB_URL"

    # Get temporary password from docker logs
    info "Getting temporary password from docker logs..."
    sleep 5
    local temp_pass
    temp_pass=$(docker logs tyr-media-qbittorrent 2>&1 | grep -oP 'temporary password.*: \K\S+' | tail -1)
    if [ -z "$temp_pass" ]; then
        err "Could not find temporary password in qBitTorrent logs"
        return 1
    fi
    log "Found temporary password"

    # Login
    info "Logging in..."
    local cookie_jar
    cookie_jar=$(mktemp)
    local login_result
    login_result=$(curl -s -c "$cookie_jar" "$QB_URL/api/v2/auth/login" \
        --data-urlencode "username=admin" \
        --data-urlencode "password=$temp_pass")

    if [ "$login_result" != "Ok." ]; then
        err "Failed to login to qBitTorrent: $login_result"
        rm -f "$cookie_jar"
        return 1
    fi
    log "Logged in"

    # If running on a custom port, disable host header validation via config file
    if [ "${QBITTORRENT_WEBUI_PORT}" != "8080" ]; then
        info "Custom port detected ($QBITTORRENT_WEBUI_PORT), disabling host header validation..."
        local qbt_conf="${QBITTORRENT_FOLDER}/qBittorrent/qBittorrent.conf"
        if [ -f "$qbt_conf" ]; then
            if grep -q "WebUI\\\\HostHeaderValidation" "$qbt_conf"; then
                sed -i 's/WebUI\\HostHeaderValidation=.*/WebUI\\HostHeaderValidation=false/' "$qbt_conf"
            else
                sed -i '/\[Preferences\]/a WebUI\\HostHeaderValidation=false' "$qbt_conf"
            fi
            log "Host header validation disabled"
        fi
    fi

    # Set all preferences via API
    info "Setting preferences..."
    local prefs
    prefs=$(cat <<'PREFS'
{
    "bypass_local_auth": true,
    "bypass_auth_subnet_whitelist_enabled": true,
    "bypass_auth_subnet_whitelist": "172.16.0.0/12",
    "web_ui_password": "qwerty",
    "save_path": "/data/downloads",
    "excluded_file_names": "*.lnk",
    "max_connec": -1,
    "max_connec_per_torrent": -1,
    "max_uploads": -1,
    "max_uploads_per_torrent": -1,
    "alt_up_limit": 4000,
    "alt_dl_limit": 10000,
    "queueing_enabled": false,
    "max_ratio_enabled": true,
    "max_ratio": 2,
    "max_seeding_time_enabled": true,
    "max_seeding_time": 10080,
    "max_inactive_seeding_time_enabled": true,
    "max_inactive_seeding_time": 10080,
    "max_ratio_act": 0,
    "memory_working_set_limit": 12288,
    "recheck_completed_torrents": true
}
PREFS
)

    curl -s -b "$cookie_jar" "$QB_URL/api/v2/app/setPreferences" \
        --data-urlencode "json=$prefs"
    log "Preferences set"

    # Verify listening port
    info "Checking listening port (PIA port forwarding)..."
    local listen_port
    listen_port=$(curl -s -b "$cookie_jar" "$QB_URL/api/v2/app/preferences" | jq -r '.listen_port')
    info "Current listening port: $listen_port"

    rm -f "$cookie_jar"
    log "qBitTorrent configuration complete"
}

# ═══════════════════════════════════════════════════════════════
#  Sonarr / Radarr (shared logic)
# ═══════════════════════════════════════════════════════════════
configure_arr() {
    local name="$1" url="$2" config_path="$3" root_folder="$4"

    section "Configuring $name"
    wait_for_service "$name" "$url"
    wait_for_file "$config_path" || { err "$name config.xml not found at $config_path"; return 1; }
    sleep 2

    local api_key
    api_key=$(get_api_key "$config_path")
    log "Got $name API key: $api_key"

    local H="X-Api-Key: $api_key"

    # ── Authentication ──
    info "Setting authentication (basic, admin/qwerty, disabled for localhost)..."
    local host_config
    host_config=$(curl -s -H "$H" "$url/api/v3/config/host")

    echo "$host_config" | jq '. +  {
        "authenticationMethod": "basic",
        "authenticationRequired": "disabledForLocalAddresses",
        "username": "admin",
        "password": "qwerty"
    }' | curl -s -X PUT -H "$H" -H "Content-Type: application/json" \
        "$url/api/v3/config/host" -d @- > /dev/null
    log "Authentication configured"

    # ── Root folder ──
    info "Adding root folder: $root_folder"
    curl -s -X POST -H "$H" -H "Content-Type: application/json" \
        "$url/api/v3/rootfolder" \
        -d "{\"path\": \"$root_folder\"}" > /dev/null 2>&1 || warn "Root folder may already exist"
    log "Root folder set"

    # ── Quality profiles ──
    info "Configuring quality profiles..."
    local profiles
    profiles=$(curl -s -H "$H" "$url/api/v3/qualityprofile")

    local any_id
    any_id=$(echo "$profiles" | jq '[.[] | select(.name == "Any")][0].id')

    if [ "$any_id" = "null" ] || [ -z "$any_id" ]; then
        warn "Could not find 'Any' quality profile - skipping profile configuration"
    else
        # Delete all profiles except "Any"
        local other_ids
        other_ids=$(echo "$profiles" | jq -r '.[] | select(.name != "Any") | .id')
        for pid in $other_ids; do
            curl -s -X DELETE -H "$H" "$url/api/v3/qualityprofile/$pid" > /dev/null 2>&1 || \
                warn "Could not delete profile $pid (may be in use)"
        done

        # Update "Any": enable all qualities, upgrades allowed, cutoff = Remux-2160p
        local any_profile
        any_profile=$(curl -s -H "$H" "$url/api/v3/qualityprofile/$any_id")

        # Find cutoff ID for Bluray-2160p Remux (Remux-2160p)
        # Look for a top-level item (group or quality) matching Remux-2160p
        local cutoff_id
        cutoff_id=$(echo "$any_profile" | jq '
            # Search top-level items: groups and standalone qualities
            [.items[] |
                # Check group name
                if .name and (.name | test("Remux.*2160|2160.*Remux"; "i")) then .id
                # Check grouped items
                elif .items then
                    ([.items[] | select(.quality.name | test("Remux.*2160|2160.*Remux"; "i"))] | if length > 0 then .[0].quality.id else empty end)
                # Check standalone quality
                elif .quality and (.quality.name | test("Remux.*2160|2160.*Remux"; "i")) then .quality.id
                else empty
                end
            ] | first // null
        ')

        # Fallback: use the last (highest) item
        if [ "$cutoff_id" = "null" ] || [ -z "$cutoff_id" ]; then
            cutoff_id=$(echo "$any_profile" | jq '.items | last | .id // .quality.id')
            warn "Could not find Remux-2160p, using highest quality as cutoff (ID: $cutoff_id)"
        fi

        # Enable all qualities and set upgrades
        echo "$any_profile" | jq --argjson cutoff "$cutoff_id" '
            .upgradeAllowed = true |
            .cutoff = $cutoff |
            .items = [.items[] |
                .allowed = true |
                if .items then
                    .items = [.items[] | .allowed = true]
                else . end
            ]
        ' | curl -s -X PUT -H "$H" -H "Content-Type: application/json" \
            "$url/api/v3/qualityprofile/$any_id" -d @- > /dev/null

        log "Quality profile 'Any' updated (all qualities, upgrades to cutoff $cutoff_id)"
    fi

    # ── Delay profile: prefer torrent ──
    info "Setting delay profile to prefer torrent..."
    local delay_profiles
    delay_profiles=$(curl -s -H "$H" "$url/api/v3/delayprofile")
    local delay_id
    delay_id=$(echo "$delay_profiles" | jq '.[0].id')

    if [ "$delay_id" != "null" ] && [ -n "$delay_id" ]; then
        echo "$delay_profiles" | jq '.[0] | .preferredProtocol = "torrent"' | \
            curl -s -X PUT -H "$H" -H "Content-Type: application/json" \
            "$url/api/v3/delayprofile/$delay_id" -d @- > /dev/null
        log "Delay profile set to prefer torrent"
    fi

    # ── Download client: qBitTorrent ──
    info "Adding qBitTorrent download client..."
    local dc_schema
    dc_schema=$(curl -s -H "$H" "$url/api/v3/downloadclient/schema" | \
        jq '[.[] | select(.implementation == "QBittorrent")][0]')

    if [ "$dc_schema" != "null" ] && [ -n "$dc_schema" ]; then
        echo "$dc_schema" | jq '
            .name = "qBitTorrent" |
            .enable = true |
            (.fields[] | select(.name == "host")).value = "localhost" |
            (.fields[] | select(.name == "port")).value = 8080
        ' | curl -s -X POST -H "$H" -H "Content-Type: application/json" \
            "$url/api/v3/downloadclient" -d @- > /dev/null 2>&1 || \
            warn "Download client may already exist"
        log "qBitTorrent download client added"
    fi

    # ── UI theme: dark ──
    info "Setting UI theme to dark..."
    local ui_config
    ui_config=$(curl -s -H "$H" "$url/api/v3/config/ui")
    echo "$ui_config" | jq '.theme = "dark"' | \
        curl -s -X PUT -H "$H" -H "Content-Type: application/json" \
        "$url/api/v3/config/ui" -d @- > /dev/null
    log "UI theme set to dark"

    # Export API key for use by other functions
    if [[ "$name" == "Sonarr" ]]; then
        SONARR_API_KEY="$api_key"
    elif [[ "$name" == "Radarr" ]]; then
        RADARR_API_KEY="$api_key"
    fi

    log "$name configuration complete"
}

configure_sonarr() {
    configure_arr "Sonarr" "$SONARR_URL" "${SONARR_FOLDER}/config.xml" "/data/media/shows"
}

configure_radarr() {
    configure_arr "Radarr" "$RADARR_URL" "${RADARR_FOLDER}/config.xml" "/data/media/movies"
}

# ═══════════════════════════════════════════════════════════════
#  Prowlarr
# ═══════════════════════════════════════════════════════════════
configure_prowlarr() {
    section "Configuring Prowlarr"

    wait_for_service "Prowlarr" "$PROWLARR_URL"
    local config_path="${PROWLARR_FOLDER}/config.xml"
    wait_for_file "$config_path" || { err "Prowlarr config.xml not found"; return 1; }
    sleep 2

    PROWLARR_API_KEY=$(get_api_key "$config_path")
    log "Got Prowlarr API key: $PROWLARR_API_KEY"

    local H="X-Api-Key: $PROWLARR_API_KEY"

    # ── Authentication ──
    info "Setting authentication (forms, admin/qwerty, disabled for localhost)..."
    local host_config
    host_config=$(curl -s -H "$H" "$PROWLARR_URL/api/v1/config/host")

    echo "$host_config" | jq '. + {
        "authenticationMethod": "forms",
        "authenticationRequired": "disabledForLocalAddresses",
        "username": "admin",
        "password": "qwerty"
    }' | curl -s -X PUT -H "$H" -H "Content-Type: application/json" \
        "$PROWLARR_URL/api/v1/config/host" -d @- > /dev/null
    log "Authentication configured"

    # ── Create flaresolverr tag ──
    info "Creating flaresolverr tag..."
    local tag_result
    tag_result=$(curl -s -X POST -H "$H" -H "Content-Type: application/json" \
        "$PROWLARR_URL/api/v1/tag" \
        -d '{"label": "flaresolverr"}' 2>/dev/null || echo '{}')

    local flaresolverr_tag_id
    flaresolverr_tag_id=$(echo "$tag_result" | jq '.id // empty')

    if [ -z "$flaresolverr_tag_id" ]; then
        # Tag might already exist, look it up
        flaresolverr_tag_id=$(curl -s -H "$H" "$PROWLARR_URL/api/v1/tag" | \
            jq '[.[] | select(.label == "flaresolverr")][0].id // empty')
    fi

    if [ -n "$flaresolverr_tag_id" ]; then
        log "FlareSolverr tag ID: $flaresolverr_tag_id"
    else
        warn "Could not create or find flaresolverr tag"
        flaresolverr_tag_id=1
    fi

    # ── FlareSolverr indexer proxy ──
    info "Adding FlareSolverr indexer proxy..."
    local proxy_schemas
    proxy_schemas=$(curl -s -H "$H" "$PROWLARR_URL/api/v1/indexerProxy/schema")

    local fs_schema
    fs_schema=$(echo "$proxy_schemas" | jq '[.[] | select(.implementation == "FlareSolverr")][0]')

    if [ "$fs_schema" != "null" ] && [ -n "$fs_schema" ]; then
        echo "$fs_schema" | jq --argjson tid "$flaresolverr_tag_id" '
            .name = "FlareSolverr" |
            .tags = [$tid] |
            (.fields[] | select(.name == "host")).value = "http://localhost:8191"
        ' | curl -s -X POST -H "$H" -H "Content-Type: application/json" \
            "$PROWLARR_URL/api/v1/indexerProxy" -d @- > /dev/null 2>&1 || \
            warn "FlareSolverr proxy may already exist"
        log "FlareSolverr indexer proxy added"
    else
        warn "FlareSolverr schema not found"
    fi

    # ── Apps: Sonarr ──
    info "Adding Sonarr app..."
    local app_schemas
    app_schemas=$(curl -s -H "$H" "$PROWLARR_URL/api/v1/applications/schema")

    local sonarr_schema
    sonarr_schema=$(echo "$app_schemas" | jq '[.[] | select(.implementation == "Sonarr")][0]')

    if [ "$sonarr_schema" != "null" ]; then
        echo "$sonarr_schema" | jq \
            --arg skey "$SONARR_API_KEY" \
            --arg pkey "$PROWLARR_API_KEY" '
            .name = "Sonarr" |
            .syncLevel = "fullSync" |
            (.fields[] | select(.name == "prowlarrUrl")).value = "http://localhost:9696" |
            (.fields[] | select(.name == "baseUrl")).value = "http://localhost:8989" |
            (.fields[] | select(.name == "apiKey")).value = $skey
        ' | curl -s -X POST -H "$H" -H "Content-Type: application/json" \
            "$PROWLARR_URL/api/v1/applications" -d @- > /dev/null 2>&1 || \
            warn "Sonarr app may already exist"
        log "Sonarr app added"
    fi

    # ── Apps: Radarr ──
    info "Adding Radarr app..."
    local radarr_schema
    radarr_schema=$(echo "$app_schemas" | jq '[.[] | select(.implementation == "Radarr")][0]')

    if [ "$radarr_schema" != "null" ]; then
        echo "$radarr_schema" | jq \
            --arg rkey "$RADARR_API_KEY" \
            --arg pkey "$PROWLARR_API_KEY" '
            .name = "Radarr" |
            .syncLevel = "fullSync" |
            (.fields[] | select(.name == "prowlarrUrl")).value = "http://localhost:9696" |
            (.fields[] | select(.name == "baseUrl")).value = "http://localhost:7878" |
            (.fields[] | select(.name == "apiKey")).value = $rkey
        ' | curl -s -X POST -H "$H" -H "Content-Type: application/json" \
            "$PROWLARR_URL/api/v1/applications" -d @- > /dev/null 2>&1 || \
            warn "Radarr app may already exist"
        log "Radarr app added"
    fi

    # ── Indexers ──
    info "Fetching indexer schemas (this may take a moment)..."
    local indexer_schemas
    indexer_schemas=$(curl -s -H "$H" "$PROWLARR_URL/api/v1/indexer/schema")

    add_indexer() {
        local def_name="$1" display_name="$2"
        shift 2

        # Check for --tags option
        local tags="[]"
        if [ "${1:-}" = "--tags" ]; then
            tags="$2"
            shift 2
        fi

        local schema
        schema=$(echo "$indexer_schemas" | jq --arg def "$def_name" \
            '[.[] | select(.definitionName == $def)][0]')

        if [ "$schema" = "null" ] || [ -z "$schema" ] || [ "$schema" = "" ]; then
            warn "Indexer schema not found for definition: $def_name"
            return 1
        fi

        # Set name, enable, and tags
        schema=$(echo "$schema" | jq --arg name "$display_name" --argjson tags "$tags" \
            '.name = $name | .enable = true | .tags = $tags')

        # Apply field overrides
        while [ $# -gt 0 ]; do
            local field_name="${1%%=*}"
            local field_value="${1#*=}"
            schema=$(echo "$schema" | jq --arg fn "$field_name" --arg fv "$field_value" '
                (.fields[] | select(.name == $fn)).value = $fv
            ')
            shift
        done

        curl -s -X POST -H "$H" -H "Content-Type: application/json" \
            "$PROWLARR_URL/api/v1/indexer" -d "$schema" > /dev/null 2>&1 && \
            log "Added indexer: $display_name" || \
            warn "Could not add indexer: $display_name"
    }

    # 1337x (public, with flaresolverr tag)
    add_indexer "1337x" "1337x" --tags "[$flaresolverr_tag_id]"

    # Kinozal (semi-private, needs account)
    add_indexer "kinozal" "Kinozal" \
        "username=$KINOZAL_USER" "password=$KINOZAL_PASS"

    # RuTracker.org (built-in, semi-private)
    add_indexer "rutracker" "RuTracker.org" \
        "username=$RUTRACKER_USER" "password=$RUTRACKER_PASS"

    # rutracker-v2 (custom yml - rutracker-org-movies)
    add_indexer "rutracker-org-movies" "rutracker-v2" \
        "username=$RUTRACKER_USER" "password=$RUTRACKER_PASS"

    # TheRARBG (custom yml, public)
    add_indexer "therarbg" "TheRARBG"

    # ── Sync indexers to apps ──
    info "Syncing indexers to apps..."
    curl -s -X POST -H "$H" -H "Content-Type: application/json" \
        "$PROWLARR_URL/api/v1/command" \
        -d '{"name": "AppIndexerSync"}' > /dev/null 2>&1 || true
    log "Indexer sync triggered"

    # ── UI theme: dark ──
    info "Setting UI theme to dark..."
    local ui_config
    ui_config=$(curl -s -H "$H" "$PROWLARR_URL/api/v1/config/ui")
    echo "$ui_config" | jq '.theme = "dark"' | \
        curl -s -X PUT -H "$H" -H "Content-Type: application/json" \
        "$PROWLARR_URL/api/v1/config/ui" -d @- > /dev/null
    log "UI theme set to dark"

    log "Prowlarr configuration complete"
}

# ═══════════════════════════════════════════════════════════════
#  Jellyfin
# ═══════════════════════════════════════════════════════════════
configure_jellyfin() {
    section "Configuring Jellyfin"

    wait_for_service "Jellyfin" "$JELLYFIN_URL"

    local EMBY_AUTH='MediaBrowser Client="ConfigureScript", Device="Server", DeviceId="configure-sh", Version="1.0.0"'

    # ── Startup wizard ──
    info "Checking startup wizard status..."
    local public_info
    public_info=$(curl -s "$JELLYFIN_URL/System/Info/Public")
    local wizard_done
    wizard_done=$(echo "$public_info" | jq -r '.StartupWizardCompleted')

    if [ "$wizard_done" != "true" ]; then
        info "Running startup wizard..."

        # Set startup configuration
        curl -s -X POST -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: $EMBY_AUTH" \
            "$JELLYFIN_URL/Startup/Configuration" \
            -d '{"UICulture": "en-US", "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en"}' > /dev/null

        # Create initial user ($MAIN_USER)
        curl -s -X POST -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: $EMBY_AUTH" \
            "$JELLYFIN_URL/Startup/User" \
            -d "{\"Name\": \"$MAIN_USER\", \"Password\": \"qwerty\"}" > /dev/null

        # Set remote access
        curl -s -X POST -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: $EMBY_AUTH" \
            "$JELLYFIN_URL/Startup/RemoteAccess" \
            -d '{"EnableRemoteAccess": true, "EnableAutomaticPortMapping": false}' > /dev/null

        # Complete wizard
        curl -s -X POST -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: $EMBY_AUTH" \
            "$JELLYFIN_URL/Startup/Complete" > /dev/null

        log "Startup wizard completed"
        sleep 3
    else
        log "Startup wizard already completed"
    fi

    # ── Authenticate ──
    info "Authenticating as $MAIN_USER..."
    local auth_result
    auth_result=$(curl -s -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $EMBY_AUTH" \
        "$JELLYFIN_URL/Users/AuthenticateByName" \
        -d "{\"Username\": \"$MAIN_USER\", \"Pw\": \"qwerty\"}")

    local JF_TOKEN
    JF_TOKEN=$(echo "$auth_result" | jq -r '.AccessToken')
    local ADMIN_ID
    ADMIN_ID=$(echo "$auth_result" | jq -r '.User.Id')

    if [ -z "$JF_TOKEN" ] || [ "$JF_TOKEN" = "null" ]; then
        err "Failed to authenticate with Jellyfin"
        return 1
    fi
    log "Authenticated (user ID: $ADMIN_ID)"

    local JF_AUTH="$EMBY_AUTH, Token=\"$JF_TOKEN\""

    # ── Create family account ──
    info "Creating family account (family/qwerty)..."
    local family_result
    family_result=$(curl -s -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH" \
        "$JELLYFIN_URL/Users/New" \
        -d '{"Name": "family"}' 2>/dev/null || echo '{}')

    local FAMILY_ID
    FAMILY_ID=$(echo "$family_result" | jq -r '.Id // empty')

    if [ -n "$FAMILY_ID" ]; then
        # Set password for family user
        curl -s -X POST -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: $JF_AUTH" \
            "$JELLYFIN_URL/Users/$FAMILY_ID/Password" \
            -d '{"NewPw": "qwerty"}' > /dev/null 2>&1 || true
        log "Created family account (ID: $FAMILY_ID)"
    else
        # Try to find existing family user
        local users
        users=$(curl -s -H "X-Emby-Authorization: $JF_AUTH" "$JELLYFIN_URL/Users")
        FAMILY_ID=$(echo "$users" | jq -r '.[] | select(.Name == "family") | .Id // empty')
        if [ -n "$FAMILY_ID" ]; then
            log "Family account already exists (ID: $FAMILY_ID)"
        else
            warn "Could not create or find family account"
        fi
    fi

    # Grant family user access to all libraries
    if [ -n "$FAMILY_ID" ]; then
        info "Granting family user access to all libraries..."
        local family_user
        family_user=$(curl -s -H "X-Emby-Authorization: $JF_AUTH" "$JELLYFIN_URL/Users/$FAMILY_ID")
        echo "$family_user" | jq '.Policy.EnableAllFolders = true | .Policy' | \
            curl -s -X POST -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: $JF_AUTH" \
            "$JELLYFIN_URL/Users/$FAMILY_ID/Policy" -d @- > /dev/null 2>&1 || true
    fi

    # ── Add libraries ──
    info "Adding libraries..."

    # Shared library options
    local lib_opts_base
    lib_opts_base=$(cat <<'LIBOPTS'
{
    "PreferredMetadataLanguage": "en",
    "MetadataCountryCode": "US",
    "AutomaticRefreshIntervalDays": 30,
    "SaveLocalMetadata": true,
    "MetadataSavers": ["Nfo"],
    "TypeOptions": [
        {
            "Type": "Movie",
            "ImageFetcherOrder": ["TheMovieDb", "The Open Movie Database"],
            "ImageFetchers": ["TheMovieDb", "The Open Movie Database"],
            "ImageOptions": [
                {"Type": "Backdrop", "Limit": 4, "MinWidth": 1200}
            ]
        },
        {
            "Type": "Series",
            "ImageFetcherOrder": ["TheMovieDb"],
            "ImageFetchers": ["TheMovieDb"],
            "ImageOptions": [
                {"Type": "Backdrop", "Limit": 4, "MinWidth": 1200}
            ]
        },
        {
            "Type": "Season",
            "ImageFetcherOrder": ["TheMovieDb"],
            "ImageFetchers": ["TheMovieDb"],
            "ImageOptions": [
                {"Type": "Backdrop", "Limit": 4, "MinWidth": 1200}
            ]
        },
        {
            "Type": "Episode",
            "ImageFetcherOrder": ["TheMovieDb", "The Open Movie Database"],
            "ImageFetchers": ["TheMovieDb", "The Open Movie Database"],
            "ImageOptions": [
                {"Type": "Backdrop", "Limit": 4, "MinWidth": 1200}
            ]
        }
    ]
}
LIBOPTS
)

    # Movies library (with auto-collection)
    local movies_opts
    movies_opts=$(echo "$lib_opts_base" | jq '. + {"AutomaticallyAddToCollection": true}')

    curl -s -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH" \
        "${JELLYFIN_URL}/Library/VirtualFolders/Add?name=Movies&collectionType=movies&refreshLibrary=false&paths=%2Fdata%2Fmedia%2Fmovies" \
        -d "{\"LibraryOptions\": $movies_opts}" > /dev/null 2>&1 && \
        log "Added Movies library (/data/media/movies)" || \
        warn "Movies library may already exist"

    # Shows library (with auto-merge series)
    local shows_opts
    shows_opts=$(echo "$lib_opts_base" | jq '. + {"EnableAutomaticSeriesGrouping": true}')

    curl -s -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH" \
        "${JELLYFIN_URL}/Library/VirtualFolders/Add?name=Shows&collectionType=tvshows&refreshLibrary=false&paths=%2Fdata%2Fmedia%2Ftvshows" \
        -d "{\"LibraryOptions\": $shows_opts}" > /dev/null 2>&1 && \
        log "Added Shows library (/data/media/tvshows)" || \
        warn "Shows library may already exist"

    # Home Videos/Photos library
    curl -s -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH" \
        "${JELLYFIN_URL}/Library/VirtualFolders/Add?name=Home+Vid%2FPhotos&collectionType=homevideos&refreshLibrary=false&paths=%2Fdata%2Fdownloads%2Fcontent" \
        -d "{\"LibraryOptions\": $lib_opts_base}" > /dev/null 2>&1 && \
        log "Added Home Vid/Photos library (/data/downloads/content)" || \
        warn "Home Vid/Photos library may already exist"

    # ── Branding ──
    info "Setting branding (login disclaimer + CSS)..."
    local branding_json
    branding_json=$(jq -n --arg disclaimer "$JELLYFIN_DISCLAIMER" '{
        "LoginDisclaimer": $disclaimer,
        "CustomCss": ".loginDisclaimer { font-size: 5rem; color: #F55; }"
    }')

    curl -s -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH" \
        "$JELLYFIN_URL/System/Configuration/branding" \
        -d "$branding_json" > /dev/null
    log "Branding configured"

    # ── Install Trakt plugin ──
    info "Installing Trakt plugin..."
    local packages
    packages=$(curl -s -H "X-Emby-Authorization: $JF_AUTH" "$JELLYFIN_URL/Packages")

    local trakt_version trakt_name
    trakt_name=$(echo "$packages" | jq -r '[.[] | select(.name == "Trakt")][0].name // empty')
    trakt_version=$(echo "$packages" | jq -r '[.[] | select(.name == "Trakt")][0].versions[0].version // empty')

    if [ -n "$trakt_name" ] && [ -n "$trakt_version" ]; then
        curl -s -X POST -H "X-Emby-Authorization: $JF_AUTH" \
            "$JELLYFIN_URL/Packages/Installed/${trakt_name}/${trakt_version}" > /dev/null 2>&1 && \
            log "Trakt plugin installed (version $trakt_version)" || \
            warn "Trakt plugin installation may have failed"
    else
        warn "Trakt plugin not found in repository"
    fi

    # ── Transcoding: NVENC for all formats (non-fatal if no NVIDIA GPU) ──
    info "Configuring transcoding (NVENC, all formats)..."
    local encoding_config
    encoding_config=$(curl -s -H "X-Emby-Authorization: $JF_AUTH" \
        "$JELLYFIN_URL/System/Configuration/encoding")

    if echo "$encoding_config" | jq '
        .HardwareAccelerationType = "nvenc" |
        .EnableHardwareEncoding = true |
        .EnableDecodingColorDepth10Hevc = true |
        .EnableDecodingColorDepth10Vp9 = true |
        .EnableEnhancedNvdecDecoder = true |
        .AllowHevcEncoding = true |
        .EnableHardwareDecoding = true |
        .HardwareDecodingCodecs = ["h264", "hevc", "mpeg2video", "mpeg4", "vc1", "vp8", "vp9", "av1"]
    ' | curl -s -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH" \
        "$JELLYFIN_URL/System/Configuration/encoding" -d @- > /dev/null; then
        log "Transcoding configured (NVENC, all formats)"
    else
        warn "Failed to configure NVENC transcoding (no NVIDIA GPU?). Skipping."
    fi

    # ── User policy: disable transcoding for main user ──
    info "Disabling transcoding for $MAIN_USER (force direct play)..."
    local admin_user
    admin_user=$(curl -s -H "X-Emby-Authorization: $JF_AUTH" "$JELLYFIN_URL/Users/$ADMIN_ID")

    echo "$admin_user" | jq '.Policy |
        .EnableVideoPlaybackTranscoding = false |
        .EnableAudioPlaybackTranscoding = false
    ' | curl -s -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH" \
        "$JELLYFIN_URL/Users/$ADMIN_ID/Policy" -d @- > /dev/null
    log "Transcoding disabled for $MAIN_USER"

    # ── User display preferences ──
    # For both users: English audio/subtitle, don't play default track, always show subtitles
    set_user_prefs() {
        local user_id="$1" user_name="$2"
        info "Setting display preferences for $user_name..."

        local user_data
        user_data=$(curl -s -H "X-Emby-Authorization: $JF_AUTH" "$JELLYFIN_URL/Users/$user_id")

        echo "$user_data" | jq '.Configuration |
            .AudioLanguagePreference = "eng" |
            .SubtitleLanguagePreference = "eng" |
            .PlayDefaultAudioTrack = false |
            .SubtitleMode = "Always"
        ' | curl -s -X POST -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: $JF_AUTH" \
            "$JELLYFIN_URL/Users/$user_id/Configuration" -d @- > /dev/null
        log "Display preferences set for $user_name"
    }

    set_user_prefs "$ADMIN_ID" "$MAIN_USER"
    if [ -n "$FAMILY_ID" ]; then
        set_user_prefs "$FAMILY_ID" "family"
    fi

    # ── Create API key for external services (Jellystat, etc.) ──
    info "Creating Jellyfin API key for external services..."
    curl -s -X POST -H "X-Emby-Authorization: $JF_AUTH" \
        "$JELLYFIN_URL/Auth/Keys?app=Jellystat" > /dev/null 2>&1 || true

    JELLYFIN_API_KEY=$(curl -s -H "X-Emby-Authorization: $JF_AUTH" \
        "$JELLYFIN_URL/Auth/Keys" | jq -r '.Items[] | select(.AppName == "Jellystat") | .AccessToken // empty')

    if [ -n "$JELLYFIN_API_KEY" ]; then
        log "Jellyfin API key created for Jellystat"
    else
        warn "Could not create Jellyfin API key - Jellystat will need manual configuration"
    fi

    # ── Scan all libraries ──
    info "Triggering library scan..."
    curl -s -X POST -H "X-Emby-Authorization: $JF_AUTH" \
        "$JELLYFIN_URL/Library/Refresh" > /dev/null
    log "Library scan triggered"

    log "Jellyfin configuration complete"
}

# ═══════════════════════════════════════════════════════════════
#  Seerr
# ═══════════════════════════════════════════════════════════════
configure_seerr() {
    section "Configuring Seerr"

    wait_for_service "Seerr" "$SEERR_URL"

    # Authenticate via Jellyfin
    info "Authenticating via Jellyfin..."
    local cookie_jar
    cookie_jar=$(mktemp)

    curl -s -X POST -H "Content-Type: application/json" \
        -c "$cookie_jar" \
        "$SEERR_URL/api/v1/auth/jellyfin" \
        -d "{
            \"username\": \"$MAIN_USER\",
            \"password\": \"qwerty\",
            \"hostname\": \"http://localhost:8096\"
        }" > /dev/null

    log "Authenticated with Seerr via Jellyfin"

    # Configure Jellyfin server connection
    info "Configuring Jellyfin server in Seerr..."
    curl -s -X POST -b "$cookie_jar" -H "Content-Type: application/json" \
        "$SEERR_URL/api/v1/settings/jellyfin" \
        -d '{
            "name": "Jellyfin",
            "hostname": "http://localhost:8096",
            "externalHostname": "",
            "enableScan": true
        }' > /dev/null 2>&1 || warn "Jellyfin settings may have failed"
    log "Jellyfin server configured"

    # Get Sonarr/Radarr profile IDs (should be "Any" - the only remaining profile)
    local sonarr_profile_id radarr_profile_id
    sonarr_profile_id=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/qualityprofile" | jq '.[0].id')
    radarr_profile_id=$(curl -s -H "X-Api-Key: $RADARR_API_KEY" \
        "$RADARR_URL/api/v3/qualityprofile" | jq '.[0].id')

    # Add Sonarr
    info "Adding Sonarr server..."
    curl -s -X POST -b "$cookie_jar" -H "Content-Type: application/json" \
        "$SEERR_URL/api/v1/settings/sonarr" \
        -d "$(jq -n \
            --arg key "$SONARR_API_KEY" \
            --argjson pid "${sonarr_profile_id:-1}" \
            '{
                "name": "Sonarr",
                "hostname": "localhost",
                "port": 8989,
                "apiKey": $key,
                "useSsl": false,
                "activeProfileId": $pid,
                "activeDirectory": "/data/media/shows",
                "activeAnimeProfileId": $pid,
                "activeAnimeDirectory": "/data/media/shows",
                "is4k": false,
                "isDefault": true,
                "enableScan": true,
                "syncEnabled": true
            }')" > /dev/null 2>&1 && \
        log "Sonarr added to Seerr" || warn "Sonarr may already be configured"

    # Add Radarr
    info "Adding Radarr server..."
    curl -s -X POST -b "$cookie_jar" -H "Content-Type: application/json" \
        "$SEERR_URL/api/v1/settings/radarr" \
        -d "$(jq -n \
            --arg key "$RADARR_API_KEY" \
            --argjson pid "${radarr_profile_id:-1}" \
            '{
                "name": "Radarr",
                "hostname": "localhost",
                "port": 7878,
                "apiKey": $key,
                "useSsl": false,
                "activeProfileId": $pid,
                "activeDirectory": "/data/media/movies",
                "is4k": false,
                "isDefault": true,
                "enableScan": true,
                "syncEnabled": true
            }')" > /dev/null 2>&1 && \
        log "Radarr added to Seerr" || warn "Radarr may already be configured"

    # Complete initial setup
    info "Completing Seerr setup..."
    curl -s -X POST -b "$cookie_jar" \
        "$SEERR_URL/api/v1/settings/initialize" > /dev/null 2>&1 || true

    # Import Jellyfin users
    info "Importing Jellyfin users..."
    curl -s -X POST -b "$cookie_jar" \
        "$SEERR_URL/api/v1/settings/jellyfin/sync" > /dev/null 2>&1 && \
        log "Jellyfin users imported" || warn "User import may have failed"

    rm -f "$cookie_jar"
    log "Seerr configuration complete"
}

# ═══════════════════════════════════════════════════════════════
#  Jellystat
# ═══════════════════════════════════════════════════════════════
configure_jellystat() {
    section "Configuring Jellystat"

    wait_for_service "Jellystat" "$JELLYSTAT_URL"

    # Sign up (create initial account)
    info "Creating Jellystat account..."
    local signup_result
    signup_result=$(curl -s -X POST -H "Content-Type: application/json" \
        "$JELLYSTAT_URL/auth/signup" \
        -d "{\"username\": \"$MAIN_USER\", \"password\": \"qwerty\"}" 2>/dev/null || echo '{}')

    if echo "$signup_result" | jq -e '.token // .id // .username' > /dev/null 2>&1; then
        log "Jellystat account created"
    else
        warn "Jellystat signup may have failed or account already exists"
    fi

    # Login to get JWT token
    info "Logging in to Jellystat..."
    local login_result
    login_result=$(curl -s -X POST -H "Content-Type: application/json" \
        "$JELLYSTAT_URL/auth/login" \
        -d "{\"username\": \"$MAIN_USER\", \"password\": \"qwerty\"}")

    local JS_TOKEN
    JS_TOKEN=$(echo "$login_result" | jq -r '.token // empty')

    if [ -z "$JS_TOKEN" ]; then
        warn "Could not login to Jellystat - configure manually at $JELLYSTAT_URL"
        return 0
    fi
    log "Logged in to Jellystat"

    # Connect to Jellyfin
    if [ -n "$JELLYFIN_API_KEY" ]; then
        info "Connecting Jellystat to Jellyfin..."
        curl -s -X POST -H "Content-Type: application/json" \
            -H "Authorization: Bearer $JS_TOKEN" \
            "$JELLYSTAT_URL/api/setconfig" \
            -d "{\"JF_HOST\": \"http://localhost:8096\", \"JF_API_KEY\": \"$JELLYFIN_API_KEY\"}" > /dev/null 2>&1 || \
        curl -s -X POST -H "Content-Type: application/json" \
            -H "Authorization: Bearer $JS_TOKEN" \
            "$JELLYSTAT_URL/proxy/setconfig" \
            -d "{\"JF_HOST\": \"http://localhost:8096\", \"JF_API_KEY\": \"$JELLYFIN_API_KEY\"}" > /dev/null 2>&1 || \
            warn "Could not configure Jellyfin connection - configure manually at $JELLYSTAT_URL"
        log "Jellystat connected to Jellyfin"
    else
        warn "No Jellyfin API key available - connect Jellystat to Jellyfin manually at $JELLYSTAT_URL"
    fi

    log "Jellystat configuration complete"
}

# ═══════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════
main() {
    echo -e "${BOLD}${CYAN}"
    echo "  ████████╗██╗   ██╗██████╗     ███╗   ███╗███████╗██████╗ ██╗ █████╗"
    echo "     ██╔══╝╚██╗ ██╔╝██╔══██╗    ████╗ ████║██╔════╝██╔══██╗██║██╔══██╗"
    echo "     ██║    ╚████╔╝ ██████╔╝    ██╔████╔██║█████╗  ██║  ██║██║███████║"
    echo "     ██║     ╚██╔╝  ██╔══██╗    ██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║"
    echo "     ██║      ██║   ██║  ██║    ██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║"
    echo "     ╚═╝      ╚═╝   ╚═╝  ╚═╝    ╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝"
    echo -e "           Auto-Setup Script${NC}"
    echo
    info "This script configures all services after start.sh has been run."
    info "Ensure all containers are running before proceeding."
    echo

    configure_qbittorrent
    configure_sonarr
    configure_radarr
    configure_prowlarr
    configure_jellyfin
    configure_seerr
    configure_jellystat

    section "Configuration Complete"
    log "All services have been configured."
    echo
    info "Post-configuration checklist:"
    info "  - Verify indexers in Sonarr & Radarr (synced from Prowlarr)"
    info "  - Restart Jellyfin to activate Trakt plugin, then configure Trakt manually:"
    info "      Uncheck all except: Scrobbling, first 3 skips, last option (don't remove from Trakt)"
    info "      Sign in to Trakt via the plugin settings"
    info "  - Kavita: Sign up at http://localhost:${KAVITA_PORT} (WIP)"
    info "  - Check qBitTorrent listening port after PIA port forwarding activates"
    echo
    warn "Manual verification needed (AI-generated API calls may be incorrect):"
    warn "  qBitTorrent:"
    warn "    - alt rate limits: verify 4000/10000 KiB/s in UI (API might expect bytes/s)"
    warn "    - RAM limit (memory_working_set_limit): may not exist in all qBT versions"
    warn "    - recheck_completed_torrents: verify preference name is correct"
    warn "    - 'Show external IP in status bar': not set (likely desktop-only, not in Web API)"
    warn "  Sonarr/Radarr:"
    warn "    - quality profile cutoff: verify it points to Remux-2160p in the UI"
    warn "    - delay profile: verify 'prefer torrent' is set correctly"
    warn "  Jellyfin:"
    warn "    - libraries: verify paths, collection types, and options are correct in Dashboard"
    warn "    - AutomaticallyAddToCollection / EnableAutomaticSeriesGrouping: field names may differ"
    warn "    - TypeOptions/ImageOptions (backdrop limit=4, minWidth=1200): format may differ"
    warn "    - Trakt plugin: verify installation succeeded (API endpoint may differ by version)"
    warn "    - encoding config: verify NVENC + all codecs enabled in Dashboard > Playback"
    warn "    - subtitle mode: verify 'Always' is set for both users in user settings"
    warn "  Seerr:"
    warn "    - entire Seerr API is uncertain (fork of Overseerr, endpoints may differ)"
    warn "    - verify Jellyfin/Sonarr/Radarr connections, scan, default server in Seerr UI"
    warn "  Jellystat:"
    warn "    - entire Jellystat API is uncertain (signup/login/config endpoints may differ)"
    warn "    - verify account creation and Jellyfin connection in Jellystat UI"
}

main "$@"
