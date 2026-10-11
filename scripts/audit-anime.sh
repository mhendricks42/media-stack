#!/usr/bin/env bash
set -euo pipefail

sonarr_url="${SONARR_URL:-http://localhost:8989}"
jellyfin_url="${JELLYFIN_URL:-http://localhost:8096}"
config_path='config/sonarr/config.xml'
seerr_settings='config/seerr/settings.json'

[[ -f "$config_path" ]] || { echo "ERROR: missing $config_path" >&2; exit 1; }
command -v curl >/dev/null || { echo 'ERROR: curl is required.' >&2; exit 1; }
command -v jq >/dev/null || { echo 'ERROR: jq is required.' >&2; exit 1; }
[[ -n "${JELLYFIN_USER:-}" && -n "${JELLYFIN_PASS:-}" ]] ||
  { echo 'ERROR: JELLYFIN_USER and JELLYFIN_PASS are required to audit the Anime library.' >&2; exit 1; }

api_key="$(sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$config_path" | head -n 1)"
[[ -n "$api_key" ]] || { echo "ERROR: Sonarr API key is missing from $config_path" >&2; exit 1; }

root_folders="$(curl -sS -f -H "X-Api-Key: $api_key" "$sonarr_url/api/v3/rootfolder")"
jq -e '.[] | select(.path == "/data/media/anime")' <<<"$root_folders" >/dev/null ||
  { echo 'FAIL: Sonarr anime root folder is missing.' >&2; exit 1; }
echo 'PASS: Sonarr anime root folder'

naming="$(curl -sS -f -H "X-Api-Key: $api_key" "$sonarr_url/api/v3/config/naming")"
jq -e '.animeEpisodeFormat | contains("{absolute")' <<<"$naming" >/dev/null ||
  { echo 'FAIL: Sonarr anime episode format does not contain an absolute-number token.' >&2; exit 1; }
echo 'PASS: Sonarr anime absolute-number naming'

series="$(curl -sS -f -H "X-Api-Key: $api_key" "$sonarr_url/api/v3/series")"
mismatches="$(jq -r '.[] | select((.path | startswith("/data/media/anime/")) and .seriesType != "anime") | "\(.title) [\(.id)] type=\(.seriesType)"' <<<"$series")"
if [[ -n "$mismatches" ]]; then
  echo 'FAIL: series under the anime root are not typed as anime:' >&2
  printf '%s\n' "$mismatches" >&2
  echo 'Run bootstrap to reconcile root-based series types.' >&2
  exit 1
fi
echo 'PASS: Sonarr series under the anime root use seriesType=anime'

[[ -f "$seerr_settings" ]] || { echo "FAIL: missing $seerr_settings" >&2; exit 1; }
jq -e '
  .sonarr[0] |
  .activeAnimeDirectory == "/data/media/anime" and
  (.activeAnimeProfileName | startswith("[Anime]"))
' "$seerr_settings" >/dev/null ||
  { echo 'FAIL: Seerr anime root/profile override is not configured.' >&2; exit 1; }
echo 'PASS: Seerr anime root and quality profile'

jellyfin_session="$(curl -sS -f -X POST "$jellyfin_url/Users/AuthenticateByName" \
  -H 'Authorization: MediaBrowser Client="media-stack", Device="anime-audit", DeviceId="media-stack-anime-audit", Version="1.0"' \
  -H 'Content-Type: application/json' \
  --data-binary "$(jq -nc --arg user "$JELLYFIN_USER" --arg pass "$JELLYFIN_PASS" '{Username:$user,Pw:$pass}')")"
jellyfin_token="$(jq -r '.AccessToken // empty' <<<"$jellyfin_session")"
[[ -n "$jellyfin_token" ]] || { echo 'FAIL: Jellyfin authentication returned no access token.' >&2; exit 1; }
jellyfin_auth="MediaBrowser Token=\"$jellyfin_token\", Client=\"media-stack\", Device=\"anime-audit\", DeviceId=\"media-stack-anime-audit\", Version=\"1.0\""
jellyfin_libraries="$(curl -sS -f "$jellyfin_url/Library/VirtualFolders" -H "Authorization: $jellyfin_auth")"
jq -e '.[] | select(.Name == "Anime") | .Locations[]? | select(. == "/data/media/anime")' <<<"$jellyfin_libraries" >/dev/null ||
  { echo 'FAIL: Jellyfin Anime library is missing /data/media/anime.' >&2; exit 1; }
echo 'PASS: Jellyfin Anime library path'

echo 'Anime automation baseline verified.'
