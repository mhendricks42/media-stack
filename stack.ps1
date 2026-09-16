param(
    [Parameter(Position = 0)]
    [string]$Command,
    [Parameter(Position = 1)]
    [string]$Arg,
    [Parameter(Position = 2)]
    [string]$Option
)

$ErrorActionPreference = 'Stop'

trap {
    Write-Host $_.Exception.Message
    exit 1
}

function Show-Usage {
    Write-Host "Usage:"
    Write-Host "  .\stack.ps1 use <linux|windows>"
    Write-Host "  .\stack.ps1 init-windows [distro] [linux-user]"
    Write-Host "  .\stack.ps1 up|down|ps|pull|config"
    Write-Host "  .\stack.ps1 setup-data"
    Write-Host "  .\stack.ps1 env [--include-tailscale]"
    Write-Host "  .\stack.ps1 bootstrap"
    Write-Host "  .\stack.ps1 import-indexers [path] [--dry-run]"
    Write-Host "  .\stack.ps1 doctor"
    Write-Host "  .\stack.ps1 backup"
    Write-Host "  .\stack.ps1 logs <service>"
    Write-Host "  .\stack.ps1 restart <service>"
    Write-Host "  .\stack.ps1 verify"
}

function Get-ActiveComposeFile {
    if ($env:COMPOSE_FILE) { return $env:COMPOSE_FILE }
    if (Test-Path '.env') {
        $composeFileLine = Get-Content '.env' | Where-Object { $_ -match '^COMPOSE_FILE=' } | Select-Object -First 1
        if ($composeFileLine) { return ($composeFileLine -replace '^COMPOSE_FILE=', '') }
    }

    return ''
}

function Get-EnvFileValue {
    param([string]$Name)

    if (-not (Test-Path '.env')) { return '' }
    $line = Get-Content '.env' | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -First 1
    if (-not $line) { return '' }
    return $line -replace "^$([regex]::Escape($Name))=", ''
}

function Write-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')

    $status = if ($Passed) { 'OK' } else { 'FAIL' }
    if ($Detail) {
        Write-Host "$status  $Name - $Detail"
    }
    else {
        Write-Host "$status  $Name"
    }
}

function Test-SecretEnvironment {
    $missing = @()
    if (-not $env:NORD_USER) { $missing += 'NORD_USER' }
    if (-not $env:NORD_PASS) { $missing += 'NORD_PASS' }
    $composeFile = Get-ActiveComposeFile
    $composeProfiles = Get-EnvFileValue 'COMPOSE_PROFILES'
    if (($composeFile -match 'linux' -or $composeProfiles -match '(^|[,;\s])tailscale([,;\s]|$)') -and -not $env:TS_AUTHKEY) {
        $missing += 'TS_AUTHKEY'
    }

    if ($missing.Count -gt 0) {
        $names = $missing -join ', '
        throw "Missing secret environment variable(s): $names. Set them in this shell or inject them from a secret manager; do not save them in .env."
    }
}

function Get-PublicIp {
    param([string[]]$Uris)

    foreach ($uri in $Uris) {
        try {
            $ip = (Invoke-RestMethod -Uri $uri -TimeoutSec 10).Trim()
            if ($ip) { return $ip }
        }
        catch {
        }
    }

    throw "Could not fetch public IP from: $($Uris -join ', ')"
}

function Invoke-Doctor {
    Test-DockerEngine

    $composeFile = Get-ActiveComposeFile
    Write-Check '.env exists' (Test-Path '.env')
    Write-Check 'active compose target' ([bool]$composeFile) $composeFile
    $hasNordUser = [bool]$env:NORD_USER
    $hasNordPass = [bool]$env:NORD_PASS
    $hasTsAuthKey = [bool]$env:TS_AUTHKEY
    $tailscaleEnabled = $composeFile -match 'linux' -or (Get-EnvFileValue 'COMPOSE_PROFILES') -match '(^|[,;\s])tailscale([,;\s]|$)'
    Write-Check 'NORD_USER set' $hasNordUser
    Write-Check 'NORD_PASS set' $hasNordPass
    if ($tailscaleEnabled) {
        Write-Check 'TS_AUTHKEY set' $hasTsAuthKey
    }
    foreach ($secretName in @('QBIT_PASS', 'SONARR_USER', 'SONARR_PASS', 'RADARR_USER', 'RADARR_PASS', 'PROWLARR_USER', 'PROWLARR_PASS', 'BAZARR_USER', 'BAZARR_PASS', 'JELLYFIN_USER', 'JELLYFIN_PASS', 'SEERR_EMAIL')) {
        Write-Check "$secretName set" ([bool][Environment]::GetEnvironmentVariable($secretName))
    }

    $previousNordUser = $env:NORD_USER
    $previousNordPass = $env:NORD_PASS
    $previousTsAuthKey = $env:TS_AUTHKEY
    if (-not $hasNordUser) { $env:NORD_USER = '__doctor_placeholder__' }
    if (-not $hasNordPass) { $env:NORD_PASS = '__doctor_placeholder__' }
    if ($tailscaleEnabled -and -not $hasTsAuthKey) { $env:TS_AUTHKEY = '__doctor_placeholder__' }

    try {
        $dataRoot = Get-EnvFileValue 'DATA_ROOT'
        Write-Check 'DATA_ROOT configured' ([bool]$dataRoot) $dataRoot

        docker compose config *> $null
        Write-Check 'compose renders' ($LASTEXITCODE -eq 0)

        $services = @('gluetun', 'sonarr', 'radarr', 'prowlarr')
        foreach ($service in $services) {
            $containerId = (docker compose ps -q $service).Trim()
            Write-Check "$service container" ([bool]$containerId)
        }

        $sonarrContainerId = (docker compose ps -q sonarr).Trim()
        if ($sonarrContainerId) {
            docker compose exec -T sonarr sh -lc "test -d /data/torrents -a -d /data/media/tv -a -d /data/media/movies" *> $null
            Write-Check 'data folders exist' ($LASTEXITCODE -eq 0)

            docker compose exec -T sonarr sh -lc 'rm -f /data/torrents/doctor-hardlink.txt /data/media/tv/doctor-hardlink.txt; echo test > /data/torrents/doctor-hardlink.txt; ln /data/torrents/doctor-hardlink.txt /data/media/tv/doctor-hardlink.txt; count=$(stat -c ''%h'' /data/torrents/doctor-hardlink.txt); rm -f /data/torrents/doctor-hardlink.txt /data/media/tv/doctor-hardlink.txt; test "$count" = 2' *> $null
            Write-Check 'hardlinks work' ($LASTEXITCODE -eq 0)
        }

        $gluetunContainerId = (docker compose ps -q gluetun).Trim()
        if ($gluetunContainerId) {
            $gluetunHealth = (docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $gluetunContainerId).Trim()
            Write-Check 'gluetun health' ($gluetunHealth -eq 'healthy') $gluetunHealth
        }

        foreach ($endpoint in @('http://localhost:9696', 'http://localhost:8989', 'http://localhost:7878')) {
            try {
                Invoke-WebRequest -Uri $endpoint -UseBasicParsing -TimeoutSec 5 | Out-Null
                Write-Check "reachable $endpoint" $true
            }
            catch {
                Write-Check "reachable $endpoint" $false $_.Exception.Message
            }
        }
    }
    finally {
        if ($hasNordUser) { $env:NORD_USER = $previousNordUser } else { Remove-Item Env:NORD_USER -ErrorAction SilentlyContinue }
        if ($hasNordPass) { $env:NORD_PASS = $previousNordPass } else { Remove-Item Env:NORD_PASS -ErrorAction SilentlyContinue }
        if ($hasTsAuthKey) { $env:TS_AUTHKEY = $previousTsAuthKey } else { Remove-Item Env:TS_AUTHKEY -ErrorAction SilentlyContinue }
    }
}

function Test-DockerEngine {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) {
        throw 'Docker CLI was not found. Install Docker Desktop and reopen this terminal.'
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & docker info *> $null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw 'Docker engine is not reachable. Start Docker Desktop, wait until it says Running, then run this command again. If it still fails, run: wsl --shutdown; then reopen Docker Desktop.'
    }
}

if (-not $Command) {
    Show-Usage
    exit 1
}

switch ($Command) {
    'use' {
        if (-not $Arg) { throw 'Missing target (linux|windows)' }
        $template = Join-Path 'env' "$Arg.env.example"
        if (-not (Test-Path $template)) { throw "Template not found: $template" }
        Copy-Item $template '.env' -Force
        Write-Host "Switched target to $Arg (.env replaced from $template)"
    }
    'init-windows' {
        $distro = if ($Arg) { $Arg } else { 'Ubuntu' }
        if ($Option) {
            & .\scripts\init-windows-dev.ps1 -Distro $distro -LinuxUser $Option
        }
        else {
            & .\scripts\init-windows-dev.ps1 -Distro $distro
        }
    }
    'up' {
        Test-DockerEngine
        Test-SecretEnvironment
        docker compose up -d
    }
    'down' {
        Test-DockerEngine
        docker compose down
    }
    'ps' {
        Test-DockerEngine
        docker compose ps
    }
    'setup-data' {
        Test-DockerEngine
        docker compose exec -T sonarr sh -lc "mkdir -p /data/torrents/incomplete /data/media/tv /data/media/movies; chown -R 1000:1000 /data/torrents /data/media; ls -la /data; ls -la /data/media"
    }
    'env' {
        if ($Arg -eq '--include-tailscale') {
            & .\scripts\set-env.ps1 -IncludeTailscale
        }
        elseif ($Arg -eq '--force') {
            & .\scripts\set-env.ps1 -Force
        }
        elseif ($Arg) {
            throw "Unknown env option: $Arg"
        }
        else {
            & .\scripts\set-env.ps1
        }
    }
    'bootstrap' {
        Test-DockerEngine
        & .\scripts\bootstrap.ps1
    }
    'import-indexers' {
        Test-DockerEngine
        $dryRun = $Arg -eq '--dry-run' -or $Option -eq '--dry-run'
        $configPath = if ($Arg -and $Arg -ne '--dry-run') { $Arg } else { '.\indexers.json' }
        if ($Arg) {
            if ($dryRun) {
                & .\scripts\import-prowlarr-indexers.ps1 -ConfigPath $configPath -DryRun
            }
            else {
                & .\scripts\import-prowlarr-indexers.ps1 -ConfigPath $configPath
            }
        }
        else {
            & .\scripts\import-prowlarr-indexers.ps1
        }
    }
    'doctor' {
        Invoke-Doctor
    }
    'config' {
        Test-DockerEngine
        Test-SecretEnvironment
        docker compose config |
            ForEach-Object {
                $_ -replace '(OPENVPN_PASSWORD:\s*).+', '$1<redacted>' `
                   -replace '(OPENVPN_USER:\s*).+', '$1<redacted>' `
                   -replace '(TS_AUTHKEY:\s*).+', '$1<redacted>'
            }
    }
    'logs' {
        if (-not $Arg) { throw 'Missing service name' }
        Test-DockerEngine
        docker compose logs -f $Arg
    }
    'restart' {
        if (-not $Arg) { throw 'Missing service name' }
        Test-DockerEngine
        docker compose restart $Arg
    }
    'pull' {
        Test-DockerEngine
        Test-SecretEnvironment
        docker compose pull
        docker compose up -d
        docker image prune -f
    }
    'backup' {
        Test-DockerEngine
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        New-Item -ItemType Directory -Force -Path 'backups' | Out-Null
        docker compose stop
        tar -czf "backups/media-stack-$timestamp.tgz" config .env docker-compose.yml compose env indexers.example.json scripts stack.ps1 stack.sh readme.md
        docker compose up -d
        Write-Host "Backup written to backups/media-stack-$timestamp.tgz"
        Write-Host 'Treat this archive as sensitive: config/ can contain API keys and session tokens.'
    }
    'verify' {
        Test-DockerEngine
        Test-SecretEnvironment
        $gluetunContainerId = (docker compose ps -q gluetun).Trim()
        if (-not $gluetunContainerId) {
            throw 'Gluetun is not running. Start the stack first with .\stack.ps1 up.'
        }

        $gluetunHealth = (docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $gluetunContainerId).Trim()
        if ($gluetunHealth -ne 'healthy') {
            docker compose logs --tail=40 gluetun
            throw "Gluetun is $gluetunHealth. Fix the tunnel first, then run verify again."
        }

        $hostIp = Get-PublicIp @('https://ipinfo.io/ip', 'https://api.ipify.org')
        $vpnIp = (docker compose exec -T gluetun sh -lc "wget -T 10 -qO- https://ipinfo.io/ip 2>/dev/null || wget -T 10 -qO- https://api.ipify.org 2>/dev/null || wget -T 10 -qO- http://ipinfo.io/ip 2>/dev/null || true").Trim()
        if (-not $vpnIp) {
            throw 'Could not read public IP from inside Gluetun. Check Gluetun logs and network connectivity.'
        }

        Write-Host "Host IP:    $hostIp"
        Write-Host "Gluetun IP: $vpnIp"
        if ($hostIp -eq $vpnIp) {
            throw 'FAIL: host and Gluetun IP match. qBittorrent may not be tunneled.'
        }
        Write-Host 'PASS: Gluetun egress differs from host.'
    }
    default {
        Show-Usage
        exit 1
    }
}
