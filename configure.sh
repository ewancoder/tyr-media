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
KAVITA_URL="http://localhost:${KAVITA_PORT}"
KAPOWARR_URL="http://localhost:${KAPOWARR_PORT}"

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
read -p "ComicVine API key (for Kapowarr, leave empty to skip): " COMICVINE_API_KEY
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

    # If running on a custom port, disable host header validation via config file
    if [ "${QBITTORRENT_WEBUI_PORT}" != "8080" ]; then
        info "Custom port detected ($QBITTORRENT_WEBUI_PORT), disabling host header validation..."
        local qbt_conf="${QBITTORRENT_FOLDER}/qBittorrent/qBittorrent.conf"
        docker stop test-media-qbittorrent
        if [ -f "$qbt_conf" ]; then
            if grep -q "WebUI\\\\HostHeaderValidation" "$qbt_conf"; then
                sed -i 's/WebUI\\HostHeaderValidation=.*/WebUI\\HostHeaderValidation=false/' "$qbt_conf"
            else
                sed -i '/\[Preferences\]/a WebUI\\HostHeaderValidation=false' "$qbt_conf"
            fi
            log "Host header validation disabled"
        fi
        docker start test-media-qbittorrent
    fi

    # Get temporary password from docker logs
    info "Getting temporary password from docker logs..."
    sleep 5
    local temp_pass
    temp_pass=$(docker logs test-media-qbittorrent 2>&1 | grep -oP 'temporary password.*: \K\S+' | tail -1)
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
    "excluded_file_names_enabled": true,
    "max_connec": -1,
    "max_connec_per_torrent": -1,
    "max_uploads": -1,
    "max_uploads_per_torrent": -1,
    "alt_up_limit": 4194304,
    "alt_dl_limit": 10485760,
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

    info 'Restarting everything'
    ./restart.sh
    sleep 5
    curl -s -c "$cookie_jar" "$QB_URL/api/v2/auth/login"

    # Verify listening port
    info "Checking listening port (PIA port forwarding)..."
    local listen_port pia_port
    listen_port=$(curl -s -b "$cookie_jar" "$QB_URL/api/v2/app/preferences" | jq -r '.listen_port')
    pia_port=$(docker logs test-media-gluetun 2>&1 | grep -oP '\[port forwarding\] port forwarded is \K\d+' | tail -1)
    if [ "$listen_port" != "$pia_port" ]; then
        err "Port mismatch: qBittorrent=$listen_port, PIA forwarded=$pia_port"
        read -rp "    [Enter] to continue anyway / Ctrl-C to abort: " _ </dev/tty
    else
        info "Port OK: qBittorrent and PIA both use port $listen_port"
        #read -rp "    [Enter] to continue: " _ </dev/tty
    fi

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

        # Update "Any": enable all qualities, upgrades allowed, cutoff = highest quality
        local any_profile
        any_profile=$(curl -s -H "$H" "$url/api/v3/qualityprofile/$any_id")

        # Use the last (highest) item as cutoff
        local cutoff_id
        cutoff_id=$(echo "$any_profile" | jq '.items | last | .id // .quality.id')

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
    local indexer_schemas app_profile_id
    indexer_schemas=$(curl -s -H "$H" "$PROWLARR_URL/api/v1/indexer/schema")
    app_profile_id=$(curl -s -H "$H" "$PROWLARR_URL/api/v1/appprofile" | jq '.[0].id // 1')
    info "Using app profile ID: $app_profile_id"

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
            return 0
        fi

        # Set name, enable, tags, and required app profile
        schema=$(echo "$schema" | jq --arg name "$display_name" --argjson tags "$tags" --argjson pid "$app_profile_id" \
            '.name = $name | .enable = true | .tags = $tags | .appProfileId = $pid')

        # Apply field overrides
        while [ $# -gt 0 ]; do
            local field_name="${1%%=*}"
            local field_value="${1#*=}"
            schema=$(echo "$schema" | jq --arg fn "$field_name" --arg fv "$field_value" '
                (.fields[] | select(.name == $fn)).value = $fv
            ')
            shift
        done

        local result
        result=$(echo "$schema" | curl -s -X POST -H "$H" -H "Content-Type: application/json" \
            "$PROWLARR_URL/api/v1/indexer" -d @-)
        if echo "$result" | jq -e '.id' > /dev/null 2>&1; then
            log "Added indexer: $display_name"
        else
            warn "Could not add indexer: $display_name — response: $result"
        fi
    }

    # 1337x (public, with flaresolverr tag)
    add_indexer "1337x" "1337x" --tags "[$flaresolverr_tag_id]"

    # Kinozal (semi-private, needs account)
    add_indexer "kinozal" "Kinozal" \
        "username=$KINOZAL_USER" "password=$KINOZAL_PASS"

    # RuTracker.org (built-in, semi-private)
    add_indexer "RuTracker.org" "RuTracker.org" \
        "username=$RUTRACKER_USER" "password=$RUTRACKER_PASS"

    # rutracker-v2 (custom yml - rutracker-org-movies)
    add_indexer "rutracker" "rutracker" \
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

    # ── Startup wizard (manual) ──
    local public_info wizard_done
    public_info=$(curl -s "$JELLYFIN_URL/System/Info/Public")
    wizard_done=$(echo "$public_info" | jq -r '.StartupWizardCompleted')

    if [ "$wizard_done" != "true" ]; then
        warn "Jellyfin startup wizard must be completed manually."
        warn "  Open: $JELLYFIN_URL"
        warn "  Username : $MAIN_USER"
        warn "  Password : qwerty"
        warn "  Remote access: enabled, no UPnP"
        warn "  Skip adding media libraries (the script will add them)"
        read -rp "    [Enter] once you have completed the wizard: " _ </dev/tty
        wait_for_service "Jellyfin (post-wizard)" "$JELLYFIN_URL"
    else
        log "Startup wizard already completed"
    fi

    # ── Authenticate ──
    info "Authenticating as $MAIN_USER with password 'qwerty'..."
    local auth_result JF_TOKEN ADMIN_ID
    auth_result=$(curl -s -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $EMBY_AUTH" \
        "$JELLYFIN_URL/Users/AuthenticateByName" \
        -d "{\"Username\": \"$MAIN_USER\", \"Pw\": \"qwerty\"}")
    JF_TOKEN=$(echo "$auth_result" | jq -r '.AccessToken // empty' 2>/dev/null || true)
    ADMIN_ID=$(echo "$auth_result" | jq -r '.User.Id // empty' 2>/dev/null || true)

    if [ -z "$JF_TOKEN" ] || [ "$JF_TOKEN" = "null" ]; then
        err "Failed to authenticate (response: $auth_result)"
        err "Make sure you used username '$MAIN_USER' and password 'qwerty' in the wizard."
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
    FAMILY_ID=$(echo "$family_result" | jq -r '.Id // empty' 2>/dev/null || true)

    if [ -n "$FAMILY_ID" ]; then
        # Set password for family user
        curl -s -X POST -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: $JF_AUTH" \
            "$JELLYFIN_URL/Users/$FAMILY_ID/Password" \
            -d '{"NewPw": "qwerty"}' > /dev/null 2>&1 || true
        log "Created family account (ID: $FAMILY_ID)"
    else
        warn "Could not create family account (response: $family_result), looking for existing..."
        # Try to find existing family user
        local users
        users=$(curl -s -H "X-Emby-Authorization: $JF_AUTH" "$JELLYFIN_URL/Users")
        FAMILY_ID=$(echo "$users" | jq -r '.[] | select(.Name == "family") | .Id // empty' 2>/dev/null || true)
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

    # Shared base library options (no TypeOptions — added per-library below)
    local lib_opts_base
    lib_opts_base=$(cat <<'LIBOPTS'
{
    "PreferredMetadataLanguage": "en",
    "MetadataCountryCode": "US",
    "AutomaticRefreshIntervalDays": 30,
    "SaveLocalMetadata": true,
    "MetadataSavers": ["Nfo"]
}
LIBOPTS
)

    # Movies library
    local movies_opts
    movies_opts=$(echo "$lib_opts_base" | jq '. + {
        "AutomaticallyAddToCollection": true,
        "TypeOptions": [{
            "Type": "Movie",
            "MetadataFetchers": ["TheMovieDb", "The Open Movie Database"],
            "MetadataFetcherOrder": ["TheMovieDb", "The Open Movie Database"],
            "ImageFetchers": ["TheMovieDb", "The Open Movie Database", "Embedded Image Extractor", "Screen Grabber"],
            "ImageFetcherOrder": ["TheMovieDb", "The Open Movie Database", "Embedded Image Extractor", "Screen Grabber"],
            "ImageOptions": [{"Type": "Backdrop", "Limit": 4, "MinWidth": 1200}]
        }]
    }')

    local lib_result
    lib_result=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH" \
        "${JELLYFIN_URL}/Library/VirtualFolders?name=Movies&collectionType=movies&refreshLibrary=false&paths=%2Fdata%2Fmedia%2Fmovies" \
        -d "{\"LibraryOptions\": $movies_opts}")
    if [ "$lib_result" = "204" ]; then log "Added Movies library (/data/media/movies)"; else warn "Movies library: HTTP $lib_result"; fi

    # Shows library
    local shows_opts
    shows_opts=$(echo "$lib_opts_base" | jq '. + {
        "EnableAutomaticSeriesGrouping": true,
        "TypeOptions": [
            {
                "Type": "Series",
                "MetadataFetchers": ["TheMovieDb", "The Open Movie Database"],
                "MetadataFetcherOrder": ["TheMovieDb", "The Open Movie Database"],
                "ImageFetchers": ["TheMovieDb"],
                "ImageFetcherOrder": ["TheMovieDb"],
                "ImageOptions": [{"Type": "Backdrop", "Limit": 4, "MinWidth": 1200}]
            },
            {
                "Type": "Season",
                "MetadataFetchers": ["TheMovieDb"],
                "MetadataFetcherOrder": ["TheMovieDb"],
                "ImageFetchers": ["TheMovieDb"],
                "ImageFetcherOrder": ["TheMovieDb"],
                "ImageOptions": [{"Type": "Backdrop", "Limit": 4, "MinWidth": 1200}]
            },
            {
                "Type": "Episode",
                "MetadataFetchers": ["TheMovieDb", "The Open Movie Database"],
                "MetadataFetcherOrder": ["TheMovieDb", "The Open Movie Database"],
                "ImageFetchers": ["TheMovieDb", "The Open Movie Database", "Embedded Image Extractor", "Screen Grabber"],
                "ImageFetcherOrder": ["TheMovieDb", "The Open Movie Database", "Embedded Image Extractor", "Screen Grabber"],
                "ImageOptions": [{"Type": "Backdrop", "Limit": 4, "MinWidth": 1200}]
            }
        ]
    }')

    lib_result=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH" \
        "${JELLYFIN_URL}/Library/VirtualFolders?name=Shows&collectionType=tvshows&refreshLibrary=false&paths=%2Fdata%2Fmedia%2Fshows" \
        -d "{\"LibraryOptions\": $shows_opts}")
    if [ "$lib_result" = "204" ]; then log "Added Shows library (/data/media/shows)"; else warn "Shows library: HTTP $lib_result"; fi

    # Home Videos/Photos library (no metadata TypeOptions needed)
    lib_result=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH" \
        "${JELLYFIN_URL}/Library/VirtualFolders?name=Downloads&collectionType=homevideos&refreshLibrary=false&paths=%2Fdata%2Fdownloads%2Fcontent" \
        -d "{\"LibraryOptions\": $lib_opts_base}")
    if [ "$lib_result" = "204" ]; then log "Added Downloads library (/data/downloads/content)"; else warn "Downloads library: HTTP $lib_result"; fi

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

    wait_for_service "Seerr" "$SEERR_URL/api/v1/status"

    # Check current setup state to determine auth method
    local public_settings media_server_type initialized
    public_settings=$(curl -s "$SEERR_URL/api/v1/settings/public")
    media_server_type=$(echo "$public_settings" | jq -r '.mediaServerType // 4')
    initialized=$(echo "$public_settings" | jq -r '.initialized // false')

    if [ "$initialized" = "true" ]; then
        log "Seerr already initialized; skipping setup"
        return 0
    fi

    # Derive the external hostname (first non-localhost entry from HOSTNAME env var)
    local ext_host
    ext_host=$(echo "$HOSTNAME" | tr ',' '\n' | grep -v '^localhost$' | head -1)

    # Authenticate — method differs based on whether Jellyfin is already configured
    local auth_payload auth_result
    if [ "$media_server_type" = "4" ]; then
        # First-time setup (NOT_CONFIGURED): include Jellyfin connection details + serverType
        info "First-time setup: configuring Jellyfin connection and creating admin user..."
        auth_payload=$(jq -n \
            --arg user "$MAIN_USER" \
            '{
                "username": $user,
                "password": "qwerty",
                "hostname": "localhost",
                "port": 8096,
                "useSsl": false,
                "urlBase": "",
                "serverType": 2
            }')
    else
        # Jellyfin already configured: simple auth (do NOT send hostname/serverType)
        info "Authenticating with Seerr..."
        auth_payload=$(jq -n \
            --arg user "$MAIN_USER" \
            '{"username": $user, "password": "qwerty"}')
    fi

    auth_result=$(curl -s -X POST -H "Content-Type: application/json" \
        "$SEERR_URL/api/v1/auth/jellyfin" -d "$auth_payload")
    if ! echo "$auth_result" | jq -e '.id' > /dev/null 2>&1; then
        warn "Seerr auth failed: $auth_result"
        return 1
    fi
    log "Authenticated with Seerr"

    # Read API key directly from settings file (avoids HttpOnly cookie jar issues)
    local api_key
    api_key=$(jq -r '.main.apiKey' "${SEERR_FOLDER}/settings.json")

    seerr_curl() {
        local method="$1"; shift
        curl -s -X "$method" -H "X-API-Key: $api_key" "$@"
    }

    # Set Jellyfin external hostname
    info "Setting Jellyfin external hostname..."
    seerr_curl POST -H "Content-Type: application/json" \
        "$SEERR_URL/api/v1/settings/jellyfin" \
        -d "$(jq -n \
            --arg ext "http://${ext_host}:${JELLYFIN_PORT}" \
            '{
                "hostname": "localhost",
                "port": 8096,
                "useSsl": false,
                "urlBase": "",
                "externalHostname": $ext
            }')" > /dev/null
    log "Jellyfin external URL: http://${ext_host}:${JELLYFIN_PORT}"

    # Read API keys from config files if not already set (e.g. configure_sonarr/radarr were skipped)
    [ -z "$SONARR_API_KEY" ] && SONARR_API_KEY=$(get_api_key "${SONARR_FOLDER}/config.xml")
    [ -z "$RADARR_API_KEY" ] && RADARR_API_KEY=$(get_api_key "${RADARR_FOLDER}/config.xml")

    # Get Sonarr/Radarr quality profile IDs and names
    local sonarr_profile radarr_profile sonarr_profile_id sonarr_profile_name radarr_profile_id radarr_profile_name
    sonarr_profile=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" "$SONARR_URL/api/v3/qualityprofile" 2>/dev/null | jq '.[0]' 2>/dev/null || echo 'null')
    sonarr_profile_id=$(echo "$sonarr_profile" | jq '.id // 1' 2>/dev/null || echo 1)
    sonarr_profile_name=$(echo "$sonarr_profile" | jq -r '.name // "Any"' 2>/dev/null || echo "Any")
    radarr_profile=$(curl -s -H "X-Api-Key: $RADARR_API_KEY" "$RADARR_URL/api/v3/qualityprofile" 2>/dev/null | jq '.[0]' 2>/dev/null || echo 'null')
    radarr_profile_id=$(echo "$radarr_profile" | jq '.id // 1' 2>/dev/null || echo 1)
    radarr_profile_name=$(echo "$radarr_profile" | jq -r '.name // "Any"' 2>/dev/null || echo "Any")

    # Add Sonarr
    info "Adding Sonarr to Seerr..."
    local sonarr_result
    sonarr_result=$(seerr_curl POST -H "Content-Type: application/json" \
        "$SEERR_URL/api/v1/settings/sonarr" \
        -d "$(jq -n \
            --arg key "$SONARR_API_KEY" \
            --argjson pid "$sonarr_profile_id" \
            --arg pname "$sonarr_profile_name" \
            --arg ext "http://${ext_host}:${SONARR_PORT}" \
            '{
                "name": "Sonarr",
                "hostname": "localhost",
                "port": 8989,
                "apiKey": $key,
                "useSsl": false,
                "baseUrl": "",
                "externalUrl": $ext,
                "activeProfileId": $pid,
                "activeProfileName": $pname,
                "activeDirectory": "/data/media/shows",
                "activeAnimeProfileId": $pid,
                "activeAnimeProfileName": $pname,
                "activeAnimeDirectory": "/data/media/shows",
                "tags": [],
                "animeTags": [],
                "is4k": false,
                "isDefault": true,
                "syncEnabled": true,
                "preventSearch": false,
                "tagRequests": false,
                "overrideRule": [],
                "seriesType": "standard",
                "animeSeriesType": "standard",
                "enableSeasonFolders": true
            }')")
    if echo "$sonarr_result" | jq -e '.id != null' > /dev/null 2>&1; then
        log "Sonarr added to Seerr"
    else
        warn "Sonarr add failed: $sonarr_result"
    fi

    # Add Radarr
    info "Adding Radarr to Seerr..."
    local radarr_result
    radarr_result=$(seerr_curl POST -H "Content-Type: application/json" \
        "$SEERR_URL/api/v1/settings/radarr" \
        -d "$(jq -n \
            --arg key "$RADARR_API_KEY" \
            --argjson pid "$radarr_profile_id" \
            --arg pname "$radarr_profile_name" \
            --arg ext "http://${ext_host}:${RADARR_PORT}" \
            '{
                "name": "Radarr",
                "hostname": "localhost",
                "port": 7878,
                "apiKey": $key,
                "useSsl": false,
                "baseUrl": "",
                "externalUrl": $ext,
                "activeProfileId": $pid,
                "activeProfileName": $pname,
                "activeDirectory": "/data/media/movies",
                "tags": [],
                "is4k": false,
                "isDefault": true,
                "syncEnabled": true,
                "preventSearch": false,
                "tagRequests": false,
                "overrideRule": [],
                "minimumAvailability": "released"
            }')")
    if echo "$radarr_result" | jq -e '.id != null' > /dev/null 2>&1; then
        log "Radarr added to Seerr"
    else
        warn "Radarr add failed: $radarr_result"
    fi

    # Mark setup as complete
    info "Finalizing Seerr setup..."
    local init_result
    init_result=$(seerr_curl POST -H "Content-Type: application/json" \
        "$SEERR_URL/api/v1/settings/initialize" -d '{}')
    if echo "$init_result" | jq -e '.initialized == true' > /dev/null 2>&1; then
        log "Seerr initialized"
    else
        warn "Seerr initialize may have failed: $init_result"
    fi

    # Import all Jellyfin users
    info "Importing Jellyfin users into Seerr..."
    local jellyfin_user_ids import_result
    jellyfin_user_ids=$(seerr_curl GET "$SEERR_URL/api/v1/settings/jellyfin/users" \
        | jq '[.[].id]' 2>/dev/null || echo '[]')
    import_result=$(seerr_curl POST -H "Content-Type: application/json" \
        "$SEERR_URL/api/v1/user/import-from-jellyfin" \
        -d "{\"jellyfinUserIds\": $jellyfin_user_ids}")
    if echo "$import_result" | jq -e 'type == "array"' > /dev/null 2>&1; then
        log "Jellyfin users imported ($(echo "$import_result" | jq 'length') new)"
    else
        warn "Jellyfin user import response: $import_result"
    fi

    log "Seerr configuration complete"
}

# ═══════════════════════════════════════════════════════════════
#  Kavita
# ═══════════════════════════════════════════════════════════════
configure_kavita() {
    section "Configuring Kavita"

    wait_for_service "Kavita" "$KAVITA_URL"

    # Register or login
    local token
    local register_result
    register_result=$(curl -s -X POST -H "Content-Type: application/json" \
        "$KAVITA_URL/api/account/register" \
        -d "{\"username\": \"$MAIN_USER\", \"password\": \"qwerty\"}")

    token=$(echo "$register_result" | jq -r '.token // empty' 2>/dev/null)
    if [ -n "$token" ]; then
        log "Kavita account created"
    else
        info "Registration failed (account may exist), trying login..."
        token=$(curl -s -X POST -H "Content-Type: application/json" \
            "$KAVITA_URL/api/account/login" \
            -d "{\"username\": \"$MAIN_USER\", \"password\": \"qwerty\"}" \
            | jq -r '.token // empty' 2>/dev/null)
        if [ -n "$token" ]; then
            log "Logged in to Kavita"
        else
            warn "Could not register or login to Kavita - configure manually at $KAVITA_URL"
            return 1
        fi
    fi

    # Enable folder watching
    info "Enabling folder watching..."
    local settings
    settings=$(curl -s -H "Authorization: Bearer $token" "$KAVITA_URL/api/settings")
    if echo "$settings" | jq -e 'has("enableFolderWatching")' > /dev/null 2>&1; then
        settings=$(echo "$settings" | jq '.enableFolderWatching = true')
        local settings_result
        settings_result=$(curl -s -X POST -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            "$KAVITA_URL/api/settings" \
            -d "$settings")
        if echo "$settings_result" | jq -e '.enableFolderWatching == true' > /dev/null 2>&1; then
            log "Folder watching enabled"
        else
            warn "Could not enable folder watching: $settings_result"
        fi
    else
        warn "Could not fetch Kavita settings"
    fi

    # Add Comics library (if none exists)
    local libraries
    libraries=$(curl -s -H "Authorization: Bearer $token" "$KAVITA_URL/api/library/libraries")
    local lib_count
    lib_count=$(echo "$libraries" | jq 'length' 2>/dev/null || echo "0")
    if [ "$lib_count" -gt 0 ]; then
        log "Kavita already has $lib_count library/libraries; skipping creation"
    else
        info "Creating Comics library..."
        local lib_result
        lib_result=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            "$KAVITA_URL/api/library/create" \
            -d '{
                "id": 0,
                "name": "Comics",
                "type": 1,
                "folders": ["/data/media/comics"],
                "folderWatching": true,
                "includeInDashboard": true,
                "includeInSearch": true,
                "manageCollections": true,
                "manageReadingLists": true,
                "allowScrobbling": false,
                "allowMetadataMatching": false,
                "enableMetadata": true,
                "removePrefixForSortName": false,
                "inheritWebLinksFromFirstChapter": false,
                "defaultLanguage": "en",
                "fileGroupTypes": [1, 2, 3, 4],
                "excludePatterns": []
            }')
        if [[ "$lib_result" =~ ^2 ]]; then
            log "Comics library created"
        else
            warn "Comics library creation returned HTTP $lib_result"
        fi
    fi

    log "Kavita configuration complete"
}

# ═══════════════════════════════════════════════════════════════
#  Kapowarr
# ═══════════════════════════════════════════════════════════════
configure_kapowarr() {
    section "Configuring Kapowarr"

    wait_for_service "Kapowarr" "$KAPOWARR_URL"

    # Get API key
    local auth_result
    auth_result=$(curl -s -X POST -H "Content-Type: application/json" \
        "$KAPOWARR_URL/api/auth" -d '{}')
    local KAP_KEY
    KAP_KEY=$(echo "$auth_result" | jq -r '.result.api_key // empty' 2>/dev/null)
    if [ -z "$KAP_KEY" ]; then
        warn "Could not get Kapowarr API key - configure manually at $KAPOWARR_URL"
        return 1
    fi
    log "Got Kapowarr API key"

    # Ensure comics folder exists on host (mounted as /data inside container)
    mkdir -p "${DATA_FOLDER}/media/comics"

    # Add root folder (if none exists)
    local root_folders
    root_folders=$(curl -s "$KAPOWARR_URL/api/rootfolder?api_key=$KAP_KEY")
    local rf_count
    rf_count=$(echo "$root_folders" | jq '.result | length' 2>/dev/null || echo "0")
    if [ "$rf_count" -gt 0 ]; then
        log "Root folder already configured; skipping"
    else
        info "Adding root folder..."
        local rf_result
        rf_result=$(curl -s -X POST -H "Content-Type: application/json" \
            "$KAPOWARR_URL/api/rootfolder?api_key=$KAP_KEY" \
            -d '{"folder": "/data/media/comics"}')
        if echo "$rf_result" | jq -e '.result.id' > /dev/null 2>&1; then
            log "Root folder added: /data/media/comics"
        else
            warn "Root folder creation failed: $rf_result"
        fi
    fi

    # Update settings
    info "Updating settings..."
    local settings_json
    settings_json=$(jq -n '{
        "download_folder": "/data/downloads",
        "concurrent_direct_downloads": 10,
        "failing_torrent_timeout": 1800,
        "flaresolverr_base_url": "http://localhost:8191"
    }')
    if [ -n "$COMICVINE_API_KEY" ]; then
        settings_json=$(echo "$settings_json" | jq --arg key "$COMICVINE_API_KEY" '. + {"comicvine_api_key": $key}')
    fi
    local settings_result
    settings_result=$(curl -s -X PUT -H "Content-Type: application/json" \
        "$KAPOWARR_URL/api/settings?api_key=$KAP_KEY" \
        -d "$settings_json")
    if echo "$settings_result" | jq -e '.error == null' > /dev/null 2>&1; then
        log "Settings updated"
    else
        warn "Settings update failed: $settings_result"
    fi

    # Add qBittorrent client (if none exists)
    local clients
    clients=$(curl -s "$KAPOWARR_URL/api/externalclients?api_key=$KAP_KEY")
    local client_count
    client_count=$(echo "$clients" | jq '.result | length' 2>/dev/null || echo "0")
    if [ "$client_count" -gt 0 ]; then
        log "Torrent client already configured; skipping"
    else
        info "Adding qBittorrent client..."
        local client_result
        client_result=$(curl -s -X POST -H "Content-Type: application/json" \
            "$KAPOWARR_URL/api/externalclients?api_key=$KAP_KEY" \
            -d '{
                "client_type": "qBittorrent",
                "title": "qBittorrent",
                "base_url": "http://localhost:8080",
                "username": "",
                "password": ""
            }')
        if echo "$client_result" | jq -e '.result.id' > /dev/null 2>&1; then
            log "qBittorrent client added"
        else
            warn "qBittorrent client addition failed: $client_result"
        fi
    fi

    log "Kapowarr configuration complete"
}

# ═══════════════════════════════════════════════════════════════
#  Jellystat
# ═══════════════════════════════════════════════════════════════
configure_jellystat() {
    section "Configuring Jellystat"

    wait_for_service "Jellystat" "$JELLYSTAT_URL"

    # Jellystat's web UI hashes passwords with CryptoJS.SHA3 (Keccak-512, not NIST SHA3) before
    # sending to the API. The script must send the same pre-hashed value so that the stored hash
    # matches what the UI sends on login. This is Keccak-512("qwerty").
    local JS_PW_HASH="b32548f2283d7b7566d74b13752e3765d1ea39cd04d8879d6228091c13ab0063199925cbf8b3fc519cfcaf373021e854fc19d581334182a803db2e5d3132ee66"

    # Check if already configured (state 2 = fully set up)
    local state
    state=$(curl -s "$JELLYSTAT_URL/auth/isConfigured" | jq -r '.state // 0')
    if [ "$state" != "2" ]; then
        # Create account (state 0: no user yet)
        if [ "$state" = "0" ]; then
            info "Creating Jellystat account..."
            local create_result
            create_result=$(curl -s -X POST -H "Content-Type: application/json" \
                "$JELLYSTAT_URL/auth/createuser" \
                -d "{\"username\": \"$MAIN_USER\", \"password\": \"$JS_PW_HASH\"}")
            if echo "$create_result" | jq -e '.token' > /dev/null 2>&1; then
                log "Jellystat account created"
            else
                warn "Jellystat account creation failed: $create_result"
                return 1
            fi
        fi

        # Login to get JWT token
        info "Logging in to Jellystat..."
        local JS_TOKEN
        JS_TOKEN=$(curl -s -X POST -H "Content-Type: application/json" \
            "$JELLYSTAT_URL/auth/login" \
            -d "{\"username\": \"$MAIN_USER\", \"password\": \"$JS_PW_HASH\"}" | jq -r '.token // empty')

        if [ -z "$JS_TOKEN" ]; then
            warn "Could not login to Jellystat - configure manually at $JELLYSTAT_URL"
            return 1
        fi
        log "Logged in to Jellystat"

        # Connect to Jellyfin
        if [ -z "$JELLYFIN_API_KEY" ]; then
            JELLYFIN_API_KEY=$(jq -r '.jellyfin.apiKey // empty' "${SEERR_FOLDER}/settings.json" 2>/dev/null || true)
        fi
        if [ -z "$JELLYFIN_API_KEY" ]; then
            warn "No Jellyfin API key available - connect Jellystat to Jellyfin manually at $JELLYSTAT_URL"
            return 0
        fi

        info "Connecting Jellystat to Jellyfin..."
        local config_result
        config_result=$(curl -s -X POST -H "Content-Type: application/json" \
            -H "Authorization: Bearer $JS_TOKEN" \
            "$JELLYSTAT_URL/auth/configSetup" \
            -d "{\"JF_HOST\": \"http://localhost:8096\", \"JF_API_KEY\": \"$JELLYFIN_API_KEY\"}")
        # configSetup returns [] on success
        if echo "$config_result" | jq -e '. == [] or (.isValid != false)' > /dev/null 2>&1; then
            log "Jellystat connected to Jellyfin"
        else
            warn "Jellystat Jellyfin connection failed: $config_result"
        fi
    else
        log "Jellystat already configured; skipping initial setup"
    fi

    # Always ensure the external Jellyfin URL is set. The /api/setExternalUrl endpoint validates
    # by actually connecting to the URL, which fails for external hostnames not resolvable inside
    # the container, so update the DB directly instead.
    local ext_host
    ext_host=$(echo "$HOSTNAME" | tr ',' '\n' | grep -v '^localhost' | head -1)
    if [ -n "$ext_host" ]; then
        local jellystat_container
        jellystat_container=$(docker ps --filter "ancestor=cyfershepard/jellystat" --format "{{.Names}}" | head -1)
        local jellystat_db_container="${jellystat_container}-db"
        if docker ps --format "{{.Names}}" | grep -q "^${jellystat_db_container}$"; then
            if docker exec "$jellystat_db_container" psql -U postgres -d jfstat \
                -c "UPDATE app_config SET settings = (settings::jsonb || '{\"EXTERNAL_URL\": \"http://${ext_host}:${JELLYFIN_PORT}\"}'::jsonb)::json WHERE \"ID\"=1;" \
                > /dev/null 2>&1; then
                log "Jellystat external Jellyfin URL set to http://${ext_host}:${JELLYFIN_PORT}"
            else
                warn "Could not set Jellystat external Jellyfin URL"
            fi
        else
            warn "Could not find Jellystat DB container (${jellystat_db_container}) to set external URL"
        fi
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
    configure_kavita
    configure_kapowarr

    section "Configuration Complete"
    log "All services have been configured."
    echo
    info "Post-configuration checklist (optional)"
    info "  - Kapowarr: set dark theme in UI (localstorage, can't be automated)"
    info "  - Kapowarr: log in to Mega if MFA allows (optional)"
    info "  - QBitTorrent: Show external IP in status bar"
}

main "$@"
