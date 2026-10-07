#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This script must be sourced so it can export variables into your current shell:"
  echo "  source ./scripts/set-env.sh"
  echo "  source ./scripts/set-env.sh --include-tailscale"
  return 1 2>/dev/null || exit 1
fi

include_tailscale=0
force=0
for arg in "$@"; do
  case "$arg" in
    --include-tailscale) include_tailscale=1 ;;
    --force) force=1 ;;
    *) echo "Unknown option: $arg"; return 1 ;;
  esac
done

read_value() {
  local name="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local required="${4:-1}"
  local current_value="${!name:-}"
  local value

  if [[ -n "$current_value" && "$force" -eq 0 ]]; then
    echo "$name is already set; keeping existing value. Use --force to replace it."
    return 0
  fi

  while true; do
    if [[ -n "$default_value" ]]; then
      read -r -p "$prompt [$default_value]: " value
      value="${value:-$default_value}"
    else
      read -r -p "$prompt: " value
    fi

    if [[ -n "$value" || "$required" -eq 0 ]]; then
      export "$name=$value"
      return 0
    fi

    echo "$name is required."
  done
}

read_secret() {
  local name="$1"
  local prompt="$2"
  local min_length="${3:-1}"
  local required="${4:-1}"
  local current_value="${!name:-}"
  local value

  if [[ -n "$current_value" && "$force" -eq 0 ]]; then
    echo "$name is already set; keeping existing value. Use --force to replace it."
    return 0
  fi

  while true; do
    read -r -s -p "$prompt: " value
    echo
    if [[ -z "$value" && "$required" -eq 0 ]]; then
      export "$name="
      return 0
    fi
    if (( ${#value} >= min_length )); then
      export "$name=$value"
      return 0
    fi
    echo "$name must be at least $min_length character(s)."
  done
}

echo "This wizard exports secrets only into the current shell session."
echo "Close this terminal to clear them, or rerun with --force to replace them."
echo

read_value QBIT_USER "qBittorrent Web UI username" "admin"
read_secret QBIT_PASS "qBittorrent Web UI password" 6

read_value SABNZBD_USER "SABnzbd Web UI username" "admin"
read_secret SABNZBD_PASS "SABnzbd Web UI password" 6

read_secret NZBGEEK_API_KEY "NZBGeek API key (blank to skip)" 1 0
read_secret NZBPLANET_API_KEY "NZBPlanet API key (blank to skip)" 1 0

read_value SAB_SERVER_HOST "Primary Usenet server host (blank to skip)" "" 0
if [[ -n "${SAB_SERVER_HOST:-}" ]]; then
  read_value SAB_SERVER_USER "Primary Usenet server username"
  read_secret SAB_SERVER_PASS "Primary Usenet server password"
  read_value SAB_SERVER_PORT "Primary Usenet server port" "563"
  read_value SAB_SERVER_CONNECTIONS "Primary Usenet server connections" "20"
fi

read_value SAB_BACKUP_SERVER_HOST "Backup/block Usenet server host (blank to skip)" "" 0
if [[ -n "${SAB_BACKUP_SERVER_HOST:-}" ]]; then
  read_value SAB_BACKUP_SERVER_USER "Backup/block Usenet server username"
  read_secret SAB_BACKUP_SERVER_PASS "Backup/block Usenet server password"
  read_value SAB_BACKUP_SERVER_PORT "Backup/block Usenet server port" "563"
  read_value SAB_BACKUP_SERVER_CONNECTIONS "Backup/block Usenet server connections" "10"
fi

read_value SONARR_USER "Sonarr UI username" "admin"
read_secret SONARR_PASS "Sonarr UI password" 6

read_value RADARR_USER "Radarr UI username" "admin"
read_secret RADARR_PASS "Radarr UI password" 6

read_value PROWLARR_USER "Prowlarr UI username" "admin"
read_secret PROWLARR_PASS "Prowlarr UI password" 6

read_value BAZARR_USER "Bazarr UI username" "admin"
read_secret BAZARR_PASS "Bazarr UI password" 6

read_value JELLYFIN_USER "Jellyfin administrator username" "admin"
read_secret JELLYFIN_PASS "Jellyfin administrator password" 6
read_secret MOONBASE_TMDB_API_KEY "Moonbase server-wide TMDB API key (blank to skip)" 1 0
read_secret MOONBASE_MDBLIST_API_KEY "Moonbase server-wide MDBList API key (blank to skip)" 1 0

read_value SEERR_EMAIL "Seerr administrator email" "admin@example.invalid"

if [[ "$include_tailscale" -eq 1 ]]; then
  read_secret TS_AUTHKEY "Tailscale auth key"
fi

echo
echo "Session environment variables set."
echo "Next: ./stack.sh bootstrap"
