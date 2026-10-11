#!/usr/bin/env bash
set -euo pipefail

sonarr_url="${SONARR_URL:-http://localhost:8989}"
config_path='config/sonarr/config.xml'
seerr_settings='config/seerr/settings.json'

[[ -f "$config_path" ]] || { echo "ERROR: missing $config_path" >&2; exit 1; }
command -v curl >/dev/null || { echo 'ERROR: curl is required.' >&2; exit 1; }
command -v jq >/dev/null || { echo 'ERROR: jq is required.' >&2; exit 1; }

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

echo 'Anime automation baseline verified.'
