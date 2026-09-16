#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./stack.sh use <linux|windows>
  ./stack.sh up|down|ps|pull|config
  ./stack.sh setup-data
  source ./scripts/set-env.sh [--include-tailscale]
  ./stack.sh bootstrap
  ./stack.sh import-indexers [path] [--dry-run]
  ./stack.sh doctor
  ./stack.sh logs <service>
  ./stack.sh restart <service>
  ./stack.sh verify
  ./stack.sh backup
EOF
}

need_arg() {
  local value="${1:-}"
  local name="${2:-argument}"
  if [[ -z "$value" ]]; then
    echo "Missing $name"
    exit 1
  fi
}

check_secret_environment() {
  missing=()
  compose_file="${COMPOSE_FILE:-}"
  if [[ -z "$compose_file" && -f .env ]]; then
    compose_file="$(awk -F= '$1 == "COMPOSE_FILE" {print $2; exit}' .env)"
  fi

  [[ -n "${NORD_USER:-}" ]] || missing+=("NORD_USER")
  [[ -n "${NORD_PASS:-}" ]] || missing+=("NORD_PASS")
  if [[ "$compose_file" == *linux* && -z "${TS_AUTHKEY:-}" ]]; then
    missing+=("TS_AUTHKEY")
  fi

  if (( ${#missing[@]} > 0 )); then
    printf 'Missing secret environment variable(s): %s\n' "${missing[*]}"
    echo "Set them in this shell or inject them from a secret manager; do not save them in .env."
    exit 1
  fi
}

check_docker_engine() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker CLI was not found. Install Docker Engine or Docker Desktop and reopen this terminal."
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "Docker engine is not reachable. Start Docker, wait until it is running, then run this command again."
    echo "On Docker Desktop/WSL, try: wsl --shutdown; then reopen Docker Desktop."
    exit 1
  fi
}

get_env_file_value() {
  local name="$1"
  [[ -f .env ]] || return 0
  awk -F= -v name="$name" '$1 == name {print $2; exit}' .env
}

get_active_compose_file() {
  if [[ -n "${COMPOSE_FILE:-}" ]]; then
    printf '%s' "$COMPOSE_FILE"
  else
    get_env_file_value COMPOSE_FILE
  fi
}

write_check() {
  local name="$1"
  local status="$2"
  local detail="${3:-}"
  if [[ "$status" == "0" ]]; then
    if [[ -n "$detail" ]]; then
      echo "OK    $name - $detail"
    else
      echo "OK    $name"
    fi
  else
    if [[ -n "$detail" ]]; then
      echo "FAIL  $name - $detail"
    else
      echo "FAIL  $name"
    fi
  fi
}

public_ip() {
  curl -fsSL --max-time 10 https://ipinfo.io/ip 2>/dev/null || curl -fsSL --max-time 10 https://api.ipify.org
}

doctor() {
  check_docker_engine

  compose_file="$(get_active_compose_file)"
  if [[ -f .env ]]; then write_check ".env exists" 0; else write_check ".env exists" 1; fi
  if [[ -n "$compose_file" ]]; then write_check "active compose target" 0 "$compose_file"; else write_check "active compose target" 1; fi

  had_nord_user=0
  had_nord_pass=0
  had_ts_authkey=0
  [[ -n "${NORD_USER:-}" ]] && had_nord_user=1
  [[ -n "${NORD_PASS:-}" ]] && had_nord_pass=1
  [[ -n "${TS_AUTHKEY:-}" ]] && had_ts_authkey=1

  if (( had_nord_user )); then write_check "NORD_USER set" 0; else write_check "NORD_USER set" 1; export NORD_USER="__doctor_placeholder__"; fi
  if (( had_nord_pass )); then write_check "NORD_PASS set" 0; else write_check "NORD_PASS set" 1; export NORD_PASS="__doctor_placeholder__"; fi
  if [[ "$compose_file" == *linux* ]]; then
    if (( had_ts_authkey )); then write_check "TS_AUTHKEY set" 0; else write_check "TS_AUTHKEY set" 1; export TS_AUTHKEY="__doctor_placeholder__"; fi
  fi

  for secret_name in QBIT_PASS SABNZBD_USER SABNZBD_PASS SONARR_USER SONARR_PASS RADARR_USER RADARR_PASS PROWLARR_USER PROWLARR_PASS BAZARR_USER BAZARR_PASS JELLYFIN_USER JELLYFIN_PASS SEERR_EMAIL; do
    if [[ -n "${!secret_name:-}" ]]; then write_check "$secret_name set" 0; else write_check "$secret_name set" 1; fi
  done

  data_root="$(get_env_file_value DATA_ROOT)"
  if [[ -n "$data_root" ]]; then write_check "DATA_ROOT configured" 0 "$data_root"; else write_check "DATA_ROOT configured" 1; fi

  if docker compose config >/dev/null 2>&1; then write_check "compose renders" 0; else write_check "compose renders" 1; fi

  for service in gluetun sabnzbd sonarr radarr prowlarr; do
    container_id="$(docker compose ps -q "$service")"
    if [[ -n "$container_id" ]]; then write_check "$service container" 0; else write_check "$service container" 1; fi
  done

  if [[ -n "$(docker compose ps -q sonarr)" ]]; then
    if docker compose exec -T sonarr sh -lc "test -d /data/usenet/incomplete -a -d /data/usenet/complete/tv -a -d /data/usenet/complete/movies -a -d /data/torrents -a -d /data/media/tv -a -d /data/media/movies" >/dev/null 2>&1; then write_check "data folders exist" 0; else write_check "data folders exist" 1; fi
    if docker compose exec -T sonarr sh -lc "rm -f /data/usenet/complete/tv/doctor-hardlink.txt /data/media/tv/doctor-hardlink.txt; echo test > /data/usenet/complete/tv/doctor-hardlink.txt; ln /data/usenet/complete/tv/doctor-hardlink.txt /data/media/tv/doctor-hardlink.txt; count=\$(stat -c '%h' /data/usenet/complete/tv/doctor-hardlink.txt); rm -f /data/usenet/complete/tv/doctor-hardlink.txt /data/media/tv/doctor-hardlink.txt; test \"\$count\" = 2" >/dev/null 2>&1; then write_check "hardlinks work" 0; else write_check "hardlinks work" 1; fi
  fi

  gluetun_container_id="$(docker compose ps -q gluetun)"
  if [[ -n "$gluetun_container_id" ]]; then
    gluetun_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$gluetun_container_id")"
    if [[ "$gluetun_health" == "healthy" ]]; then write_check "gluetun health" 0 "$gluetun_health"; else write_check "gluetun health" 1 "$gluetun_health"; fi
  fi

  for endpoint in http://localhost:8081 http://localhost:9696 http://localhost:8989 http://localhost:7878; do
    if curl -fsSL --max-time 5 "$endpoint" >/dev/null 2>&1; then write_check "reachable $endpoint" 0; else write_check "reachable $endpoint" 1; fi
  done

  if (( ! had_nord_user )); then unset NORD_USER; fi
  if (( ! had_nord_pass )); then unset NORD_PASS; fi
  if (( ! had_ts_authkey )); then unset TS_AUTHKEY; fi
}

cmd="${1:-}"
arg="${2:-}"
option="${3:-}"

case "$cmd" in
  use)
    need_arg "$arg" "target (linux|windows)"
    src="env/${arg}.env.example"
    if [[ ! -f "$src" ]]; then
      echo "Template not found: $src"
      exit 1
    fi
    cp "$src" .env
    echo "Switched target to $arg (.env replaced from $src)"
    ;;
  up)
    check_docker_engine
    check_secret_environment
    docker compose up -d
    ;;
  down)
    check_docker_engine
    docker compose down
    ;;
  ps)
    check_docker_engine
    docker compose ps
    ;;
  setup-data)
    check_docker_engine
    docker compose exec -T sonarr sh -lc "mkdir -p /data/usenet/incomplete /data/usenet/complete/tv /data/usenet/complete/movies /data/torrents/incomplete /data/media/tv /data/media/movies; chown -R 1000:1000 /data/usenet /data/torrents /data/media; ls -la /data; ls -la /data/usenet; ls -la /data/media"
    ;;
  bootstrap)
    check_docker_engine
    if ! command -v pwsh >/dev/null 2>&1; then
      echo "PowerShell 7 (pwsh) is required for bootstrap on Linux. Install pwsh, then run ./stack.sh bootstrap."
      exit 1
    fi
    pwsh ./scripts/bootstrap.ps1
    ;;
  import-indexers)
    check_docker_engine
    if ! command -v pwsh >/dev/null 2>&1; then
      echo "PowerShell 7 (pwsh) is required for import-indexers on Linux. Install pwsh or run scripts/import-prowlarr-indexers.ps1 from Windows."
      exit 1
    fi
    dry_run=""
    config_path="$arg"
    if [[ "$arg" == "--dry-run" ]]; then
      dry_run="-DryRun"
      config_path=""
    elif [[ "$option" == "--dry-run" ]]; then
      dry_run="-DryRun"
    fi
    if [[ -n "$config_path" ]]; then
      if [[ -n "$dry_run" ]]; then
        pwsh ./scripts/import-prowlarr-indexers.ps1 -ConfigPath "$config_path" -DryRun
      else
        pwsh ./scripts/import-prowlarr-indexers.ps1 -ConfigPath "$config_path"
      fi
    elif [[ -n "$dry_run" ]]; then
      pwsh ./scripts/import-prowlarr-indexers.ps1 -DryRun
    else
      pwsh ./scripts/import-prowlarr-indexers.ps1
    fi
    ;;
  doctor)
    doctor
    ;;
  config)
    check_docker_engine
    check_secret_environment
    docker compose config | sed -E 's/(OPENVPN_PASSWORD:[[:space:]]*).+/\1<redacted>/; s/(OPENVPN_USER:[[:space:]]*).+/\1<redacted>/; s/(TS_AUTHKEY:[[:space:]]*).+/\1<redacted>/'
    ;;
  logs)
    need_arg "$arg" "service"
    check_docker_engine
    docker compose logs -f "$arg"
    ;;
  restart)
    need_arg "$arg" "service"
    check_docker_engine
    docker compose restart "$arg"
    ;;
  pull)
    check_docker_engine
    check_secret_environment
    docker compose pull
    docker compose up -d
    docker image prune -f
    ;;
  verify)
    check_docker_engine
    check_secret_environment
    gluetun_container_id="$(docker compose ps -q gluetun)"
    if [[ -z "$gluetun_container_id" ]]; then
      echo "Gluetun is not running. Start the stack first with ./stack.sh up."
      exit 1
    fi

    gluetun_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$gluetun_container_id")"
    if [[ "$gluetun_health" != "healthy" ]]; then
      docker compose logs --tail=40 gluetun
      echo "Gluetun is $gluetun_health. Fix the tunnel first, then run verify again."
      exit 1
    fi

    host_ip="$(public_ip | tr -d '[:space:]')"
    vpn_ip="$(docker compose exec -T gluetun sh -lc 'wget -T 10 -qO- https://ipinfo.io/ip 2>/dev/null || wget -T 10 -qO- https://api.ipify.org 2>/dev/null || wget -T 10 -qO- http://ipinfo.io/ip 2>/dev/null || true' | tr -d '[:space:]')"
    if [[ -z "$vpn_ip" ]]; then
      echo "Could not read public IP from inside Gluetun. Check Gluetun logs and network connectivity."
      exit 1
    fi

    echo "Host IP:    $host_ip"
    echo "Gluetun IP: $vpn_ip"
    if [[ "$host_ip" == "$vpn_ip" ]]; then
      echo "FAIL: host and Gluetun IP match. qBittorrent may not be tunneled."
      exit 1
    fi
    echo "PASS: Gluetun egress differs from host."
    ;;
  backup)
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p backups
    docker compose stop
    tar -czf "backups/media-stack-$ts.tgz" config .env docker-compose.yml compose env
    docker compose up -d
    echo "Backup written to backups/media-stack-$ts.tgz"
    echo "Treat this archive as sensitive: config/ can contain API keys and session tokens."
    ;;
  *)
    usage
    exit 1
    ;;
esac
