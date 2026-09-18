#!/bin/bash

########################################################################
# Configure Seerr with Sonarr/Radarr services and quality profiles
#
# This script:
# 1. Waits for Seerr to be healthy
# 2. Reads API keys from Sonarr/Radarr config files
# 3. Queries their APIs to find quality profile IDs
# 4. Updates Seerr's settings.json with the correct configuration
#
# Called from bootstrap.sh after Seerr is initialized.
########################################################################

set -e

SONARR_EXTERNAL_URL="${1:-http://localhost:8989}"
RADARR_EXTERNAL_URL="${2:-http://localhost:7878}"

wait_seerr_healthy() {
    local timeout=120
    local deadline=$(($(date +%s) + timeout))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -sf http://localhost:5055/api/v1/status &>/dev/null; then
            echo "Seerr is healthy."
            return 0
        fi
        sleep 3
    done

    echo "ERROR: Seerr did not become healthy within timeout."
    return 1
}

get_api_key_from_config() {
    local path="$1"

    if [ ! -f "$path" ]; then
        echo "ERROR: Missing config file: $path"
        return 1
    fi

    # Extract ApiKey from XML using sed
    grep -oP '(?<=<ApiKey>)[^<]+' "$path" | head -1
}

get_arr_quality_profiles() {
    local base_url="$1"
    local api_key="$2"
    local app_name="$3"

    curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/qualityprofile" | jq 'sort_by(.id)' || {
        echo "ERROR: $app_name quality profile lookup failed"
        return 1
    }
}

find_profile_id() {
    local profiles="$1"
    shift
    local names=("$@")

    for name in "${names[@]}"; do
        local id=$(echo "$profiles" | jq -r ".[] | select(.name == \"$name\") | .id" | head -1)
        if [ -n "$id" ] && [ "$id" != "null" ]; then
            echo "$id"
            return 0
        fi
    done

    # Default to first profile
    echo "$profiles" | jq -r '.[0].id'
}

get_profile_name() {
    local profiles="$1"
    local id="$2"

    echo "$profiles" | jq -r ".[] | select(.id == $id) | .name" | head -1
}

update_seerr_settings() {
    local settings_path="$1"
    local service="$2"
    local profile_id="$3"
    local profile_name="$4"
    local api_key="$5"

    if [ ! -f "$settings_path" ]; then
        echo "ERROR: Missing Seerr settings file: $settings_path"
        return 1
    fi

    # Backup and update
    cp "$settings_path" "$settings_path.bak"

    if [ "$service" = "sonarr" ]; then
        jq --arg api_key "$api_key" --arg profile_id "$profile_id" --arg profile_name "$profile_name" \
            '.sonarr[0].apiKey = $api_key |
             .sonarr[0].activeProfileId = ($profile_id | tonumber) |
             .sonarr[0].activeProfileName = $profile_name |
             .sonarr[0].activeAnimeProfileId = ($profile_id | tonumber) |
             .sonarr[0].activeAnimeProfileName = $profile_name' \
            "$settings_path" > "$settings_path.tmp" && mv "$settings_path.tmp" "$settings_path"
        echo "Updated Seerr Sonarr config: profile $profile_id ($profile_name)"
    elif [ "$service" = "radarr" ]; then
        jq --arg api_key "$api_key" --arg profile_id "$profile_id" --arg profile_name "$profile_name" \
            '.radarr[0].apiKey = $api_key |
             .radarr[0].activeProfileId = ($profile_id | tonumber) |
             .radarr[0].activeProfileName = $profile_name' \
            "$settings_path" > "$settings_path.tmp" && mv "$settings_path.tmp" "$settings_path"
        echo "Updated Seerr Radarr config: profile $profile_id ($profile_name)"
    fi

    echo "Seerr settings updated. Backup: $settings_path.bak"
}

echo "Configuring Seerr with Sonarr and Radarr..."

wait_seerr_healthy || exit 1

sonarr_api_key=$(get_api_key_from_config './config/sonarr/config.xml') || exit 1
radarr_api_key=$(get_api_key_from_config './config/radarr/config.xml') || exit 1

echo "Fetching quality profiles from Sonarr..."
sonarr_profiles=$(get_arr_quality_profiles "$SONARR_EXTERNAL_URL" "$sonarr_api_key" "Sonarr") || exit 1
sonarr_profile_id=$(find_profile_id "$sonarr_profiles" "WEB-1080p" "HD-1080p" "[Anime] Remux-1080p") || exit 1
sonarr_profile_name=$(get_profile_name "$sonarr_profiles" "$sonarr_profile_id") || exit 1

echo "Fetching quality profiles from Radarr..."
radarr_profiles=$(get_arr_quality_profiles "$RADARR_EXTERNAL_URL" "$radarr_api_key" "Radarr") || exit 1
radarr_profile_id=$(find_profile_id "$radarr_profiles" "HD Bluray + WEB" "HD-1080p" "Remux-1080p") || exit 1
radarr_profile_name=$(get_profile_name "$radarr_profiles" "$radarr_profile_id") || exit 1

update_seerr_settings './config/seerr/settings.json' 'sonarr' "$sonarr_profile_id" "$sonarr_profile_name" "$sonarr_api_key" || exit 1
update_seerr_settings './config/seerr/settings.json' 'radarr' "$radarr_profile_id" "$radarr_profile_name" "$radarr_api_key" || exit 1

echo "Seerr bootstrap complete. Restart Seerr to reload settings:"
echo "  docker compose restart seerr"
