#!/usr/bin/env bash

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

set -euo pipefail

SONARR_EXTERNAL_URL="${1:-http://localhost:8989}"
RADARR_EXTERNAL_URL="${2:-http://localhost:7878}"

wait_seerr_healthy() {
    local timeout=120
    local deadline
    deadline=$(($(date +%s) + timeout))

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

    sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$path" | head -n 1
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
        local id
        id="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .id' <<<"$profiles" | head -n 1)"
        if [ -n "$id" ] && [ "$id" != "null" ]; then
            echo "$id"
            return 0
        fi
    done

    # Default to first profile
    jq -r '.[0].id' <<<"$profiles"
}

get_profile_name() {
    local profiles="$1"
    local id="$2"

    jq -r --argjson id "$id" '.[] | select(.id == $id) | .name' <<<"$profiles" | head -n 1
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

    cp "$settings_path" "$settings_path.bak"

    if [ "$service" = "sonarr" ]; then
        jq --arg api_key "$api_key" --arg profile_id "$profile_id" --arg profile_name "$profile_name" \
            '.sonarr = (if (.sonarr | length) == 0 then [{}] else .sonarr end) |
             .sonarr[0] += {
               name: "Sonarr", hostname: "sonarr", port: 8989, apiKey: $api_key,
               useSsl: false, activeProfileId: ($profile_id | tonumber),
               activeProfileName: $profile_name, activeDirectory: "/data/media/tv",
               activeAnimeProfileId: ($profile_id | tonumber),
               activeAnimeProfileName: $profile_name, activeAnimeDirectory: "/data/media/tv",
               tags: [], animeTags: [], is4k: false, isDefault: true,
               enableSeasonFolders: true, syncEnabled: true, preventSearch: false,
               tagRequests: false, monitorNewItems: "all", id: 0
             }' \
            "$settings_path" > "$settings_path.tmp" && mv "$settings_path.tmp" "$settings_path"
        echo "Updated Seerr Sonarr config: profile $profile_id ($profile_name)"
    elif [ "$service" = "radarr" ]; then
        jq --arg api_key "$api_key" --arg profile_id "$profile_id" --arg profile_name "$profile_name" \
            '.radarr = (if (.radarr | length) == 0 then [{}] else .radarr end) |
             .radarr[0] += {
               name: "Radarr", hostname: "radarr", port: 7878, apiKey: $api_key,
               useSsl: false, activeProfileId: ($profile_id | tonumber),
               activeProfileName: $profile_name, activeDirectory: "/data/media/movies",
               is4k: false, minimumAvailability: "released", tags: [], isDefault: true,
               syncEnabled: true, preventSearch: false, tagRequests: false, id: 0
             }' \
            "$settings_path" > "$settings_path.tmp" && mv "$settings_path.tmp" "$settings_path"
        echo "Updated Seerr Radarr config: profile $profile_id ($profile_name)"
    fi

    echo "Seerr settings updated. Backup: $settings_path.bak"
}

echo "Configuring Seerr with Sonarr and Radarr..."

wait_seerr_healthy || exit 1

settings_path='./config/seerr/settings.json'
if [ ! -f "$settings_path" ]; then
    echo "ERROR: Missing Seerr settings file: $settings_path"
    exit 1
fi
if ! jq -e '.main.apiKey? | strings | length > 0' "$settings_path" >/dev/null; then
    seerr_api_key="$(python3 -c 'import base64, secrets; print(base64.b64encode(secrets.token_bytes(48)).decode())')"
    cp "$settings_path" "$settings_path.bak"
    jq --arg key "$seerr_api_key" '.main = (.main // {}) | .main.apiKey = $key' \
        "$settings_path" > "$settings_path.tmp" && mv "$settings_path.tmp" "$settings_path"
    unset seerr_api_key
    echo "Seerr API key generated. Backup: $settings_path.bak"
else
    echo "Seerr API key verified."
fi

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

update_seerr_settings "$settings_path" 'sonarr' "$sonarr_profile_id" "$sonarr_profile_name" "$sonarr_api_key" || exit 1
update_seerr_settings "$settings_path" 'radarr' "$radarr_profile_id" "$radarr_profile_name" "$radarr_api_key" || exit 1

echo "Seerr bootstrap complete. Restart Seerr to reload settings:"
echo "  docker compose restart seerr"
