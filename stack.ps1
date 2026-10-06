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
    Write-Host "  .\stack.ps1 init-vpn"
    Write-Host "  .\stack.ps1 init-windows [distro] [linux-user]"
    Write-Host "  .\stack.ps1 up|down|ps|pull|config"
    Write-Host "  .\stack.ps1 setup-data"
    Write-Host "  .\stack.ps1 env [--include-tailscale]"
    Write-Host "  .\stack.ps1 bootstrap"
    Write-Host "  .\stack.ps1 import-indexers [path] [--dry-run]"
    Write-Host "  .\stack.ps1 sync-profiles [--preview]"
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

function Test-RuntimeSecrets {
    $missing = @()
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

function Test-VpnSecrets {
    $composeFile = Get-ActiveComposeFile
    if ($composeFile -notmatch 'compose[/\\]secrets\.yml') {
        throw 'compose\secrets.yml is missing from COMPOSE_FILE. Run .\stack.ps1 use windows or add the overlay to .env.'
    }

    foreach ($path in @('secrets\openvpn_user', 'secrets\openvpn_password')) {
        if (-not (Test-Path $path) -or (Get-Item $path).Length -eq 0) {
            throw "Missing or empty VPN secret: $path. Run .\stack.ps1 init-vpn."
        }

        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes -contains 10 -or $bytes -contains 13) {
            throw "VPN secret contains a newline: $path. Recreate it with .\stack.ps1 init-vpn; do not use echo."
        }
    }
}

function Initialize-VpnSecrets {
    $username = Read-Host 'NordVPN OpenVPN/manual username' -AsSecureString
    $password = Read-Host 'NordVPN OpenVPN/manual password' -AsSecureString
    $usernamePointer = [IntPtr]::Zero
    $passwordPointer = [IntPtr]::Zero

    try {
        $usernamePointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($username)
        $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
        $usernameText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($usernamePointer)
        $passwordText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
        if (-not $usernameText -or -not $passwordText) {
            throw 'VPN username and password are required.'
        }

        New-Item -ItemType Directory -Force -Path 'secrets' | Out-Null
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        foreach ($sid in @(
            [Security.Principal.WindowsIdentity]::GetCurrent().User,
            [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        )) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
        }
        Set-Acl -Path 'secrets' -AclObject $acl

        $encoding = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $PWD 'secrets\openvpn_user'), $usernameText, $encoding)
        [IO.File]::WriteAllText((Join-Path $PWD 'secrets\openvpn_password'), $passwordText, $encoding)
    }
    finally {
        if ($usernamePointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($usernamePointer) }
        if ($passwordPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer) }
        $username.Dispose()
        $password.Dispose()
        Remove-Variable usernameText, passwordText -ErrorAction SilentlyContinue
        Remove-Item Env:NORD_USER, Env:NORD_PASS, Env:VPN_USER, Env:VPN_PASS -ErrorAction SilentlyContinue
    }

    Write-Host 'VPN secret files created with no trailing newline.'
}

function Get-ArrApiKey {
    param([string]$Path, [string]$AppName)

    if (-not (Test-Path $Path)) {
        throw "Missing $AppName config: $Path. Start the stack once with .\stack.ps1 up before syncing profiles."
    }

    $apiKey = [string]([xml](Get-Content $Path)).Config.ApiKey
    if (-not $apiKey) {
        throw "No ApiKey found in $Path."
    }

    return $apiKey
}

function Invoke-Recyclarr {
    param([switch]$Preview)

    Test-DockerEngine

    New-Item -ItemType Directory -Force -Path 'config\recyclarr' | Out-Null
    $configFile = 'config\recyclarr\recyclarr.yml'
    if (-not (Test-Path $configFile)) {
        if (-not (Test-Path 'recyclarr.example.yml')) {
            throw 'Missing recyclarr.example.yml and config\recyclarr\recyclarr.yml. Restore one of them, then run sync-profiles again.'
        }
        Copy-Item 'recyclarr.example.yml' $configFile
        Write-Host "Created $configFile from recyclarr.example.yml. Edit it to change which TRaSH templates are applied."
    }

    $env:SONARR_API_KEY = Get-ArrApiKey 'config\sonarr\config.xml' 'Sonarr'
    $env:RADARR_API_KEY = Get-ArrApiKey 'config\radarr\config.xml' 'Radarr'

    try {
        if ($Preview) {
            docker compose run --rm recyclarr sync --preview
        }
        else {
            docker compose run --rm recyclarr sync
        }
    }
    finally {
        Remove-Item Env:SONARR_API_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:RADARR_API_KEY -ErrorAction SilentlyContinue
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
    $hasTsAuthKey = [bool]$env:TS_AUTHKEY
    $tailscaleEnabled = $composeFile -match 'linux' -or (Get-EnvFileValue 'COMPOSE_PROFILES') -match '(^|[,;\s])tailscale([,;\s]|$)'
    Write-Check 'VPN secrets overlay' ($composeFile -match 'compose[/\\]secrets\.yml') $(if ($composeFile -match 'compose[/\\]secrets\.yml') { '' } else { 'add compose\secrets.yml to COMPOSE_FILE' })
    foreach ($path in @('secrets\openvpn_user', 'secrets\openvpn_password')) {
        $valid = $false
        if ((Test-Path $path) -and (Get-Item $path).Length -gt 0) {
            $bytes = [IO.File]::ReadAllBytes($path)
            $valid = $bytes -notcontains 10 -and $bytes -notcontains 13
        }
        Write-Check $path $valid $(if ($valid) { '' } else { 'run .\stack.ps1 init-vpn' })
    }
    if ($tailscaleEnabled) {
        Write-Check 'TS_AUTHKEY set' $hasTsAuthKey
    }
    foreach ($secretName in @('QBIT_PASS', 'SABNZBD_USER', 'SABNZBD_PASS', 'SONARR_USER', 'SONARR_PASS', 'RADARR_USER', 'RADARR_PASS', 'PROWLARR_USER', 'PROWLARR_PASS', 'BAZARR_USER', 'BAZARR_PASS', 'JELLYFIN_USER', 'JELLYFIN_PASS', 'SEERR_EMAIL')) {
        Write-Check "$secretName set" ([bool][Environment]::GetEnvironmentVariable($secretName))
    }

    $previousTsAuthKey = $env:TS_AUTHKEY
    if ($tailscaleEnabled -and -not $hasTsAuthKey) { $env:TS_AUTHKEY = '__doctor_placeholder__' }

    try {
        $dataRoot = Get-EnvFileValue 'DATA_ROOT'
        Write-Check 'DATA_ROOT configured' ([bool]$dataRoot) $dataRoot
        $recyclarrConfigured = Test-Path 'config\recyclarr\recyclarr.yml'
        Write-Check 'recyclarr config' $recyclarrConfigured $(if ($recyclarrConfigured) { '' } else { 'run sync-profiles to create it' })

        docker compose config *> $null
        Write-Check 'compose renders' ($LASTEXITCODE -eq 0)

        $services = @('gluetun', 'sabnzbd', 'sonarr', 'radarr', 'prowlarr', 'ersatztv')
        foreach ($service in $services) {
            $containerId = (docker compose ps -q $service).Trim()
            Write-Check "$service container" ([bool]$containerId)
        }

        $sonarrContainerId = (docker compose ps -q sonarr).Trim()
        if ($sonarrContainerId) {
            docker compose exec -T sonarr sh -lc "test -d /data/usenet/incomplete -a -d /data/usenet/complete/tv -a -d /data/usenet/complete/movies -a -d /data/torrents -a -d /data/media/tv -a -d /data/media/movies" *> $null
            Write-Check 'data folders exist' ($LASTEXITCODE -eq 0)

            docker compose exec -T sonarr sh -lc 'rm -f /data/usenet/complete/tv/doctor-hardlink.txt /data/media/tv/doctor-hardlink.txt; echo test > /data/usenet/complete/tv/doctor-hardlink.txt; ln /data/usenet/complete/tv/doctor-hardlink.txt /data/media/tv/doctor-hardlink.txt; count=$(stat -c ''%h'' /data/usenet/complete/tv/doctor-hardlink.txt); rm -f /data/usenet/complete/tv/doctor-hardlink.txt /data/media/tv/doctor-hardlink.txt; test "$count" = 2' *> $null
            Write-Check 'hardlinks work' ($LASTEXITCODE -eq 0)
        }

        $gluetunContainerId = (docker compose ps -q gluetun).Trim()
        if ($gluetunContainerId) {
            $gluetunHealth = (docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $gluetunContainerId).Trim()
            Write-Check 'gluetun health' ($gluetunHealth -eq 'healthy') $gluetunHealth
        }

        foreach ($endpoint in @('http://localhost:8081', 'http://localhost:9696', 'http://localhost:8989', 'http://localhost:7878', 'http://localhost:8409')) {
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
        if ($hasTsAuthKey) { $env:TS_AUTHKEY = $previousTsAuthKey } else { Remove-Item Env:TS_AUTHKEY -ErrorAction SilentlyContinue }
    }
}

function Test-DockerEngineReady {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & docker version --format '{{.Server.Version}}' *> $null
        return $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-DockerDesktopPath {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }

    return ''
}

function Start-DockerDesktop {
    if (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue) { return $true }

    $dockerDesktop = Get-DockerDesktopPath
    if (-not $dockerDesktop) { return $false }

    Write-Host 'Starting Docker Desktop...'
    Start-Process -FilePath $dockerDesktop | Out-Null
    return $true
}

function Wait-DockerEngine {
    param([int]$TimeoutSeconds = 300)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastNotice = Get-Date
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerEngineReady) { return $true }
        if (((Get-Date) - $lastNotice).TotalSeconds -ge 30) {
            $remaining = [int]($deadline - (Get-Date)).TotalSeconds
            Write-Host "  still waiting for Docker... (${remaining}s left)"
            $lastNotice = Get-Date
        }
        Start-Sleep -Seconds 3
    }

    return Test-DockerEngineReady
}

function Test-DockerEngine {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) {
        throw 'Docker CLI was not found. Install Docker Desktop and reopen this terminal.'
    }

    if (Test-DockerEngineReady) { return }

    if ($env:MEDIA_STACK_NO_DOCKER_AUTOSTART) {
        throw 'Docker engine is not reachable and auto-start is disabled by MEDIA_STACK_NO_DOCKER_AUTOSTART. Start Docker Desktop, then run this command again.'
    }

    if (-not (Start-DockerDesktop)) {
        throw 'Docker engine is not reachable and Docker Desktop was not found. Install or start Docker Desktop, then run this command again.'
    }

    Write-Host 'Waiting for the Docker engine to become ready...'
    if (-not (Wait-DockerEngine)) {
        throw 'Docker Desktop was started but the engine did not become ready in time. Check Docker Desktop, or run: wsl --shutdown; then reopen Docker Desktop.'
    }

    Write-Host 'Docker engine is ready.'
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
    'init-vpn' {
        Initialize-VpnSecrets
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
        Test-RuntimeSecrets
        Test-VpnSecrets
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
        $setupDataScript = @'
set -eu
: "${PUID:?PUID is not set in the Sonarr container}"
: "${PGID:?PGID is not set in the Sonarr container}"

for path in \
  /data/usenet \
  /data/usenet/incomplete \
  /data/usenet/complete \
  /data/usenet/complete/tv \
  /data/usenet/complete/movies \
  /data/torrents \
  /data/torrents/incomplete \
  /data/media \
  /data/media/tv \
  /data/media/movies
do
  if [ -d "$path" ]; then
    echo "Keeping existing directory: $path"
  else
    mkdir "$path"
    chown "$PUID:$PGID" "$path"
    echo "Created directory: $path ($PUID:$PGID)"
  fi
done

ls -la /data
ls -la /data/usenet
ls -la /data/media
'@
        docker compose exec -T sonarr sh -lc $setupDataScript
        if ($LASTEXITCODE -ne 0) {
            throw "Data directory setup failed with exit code $LASTEXITCODE."
        }
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
    'sync-profiles' {
        if ($Arg -and $Arg -ne '--preview') { throw "Unknown sync-profiles option: $Arg" }
        if ($Arg -eq '--preview') {
            Invoke-Recyclarr -Preview
        }
        else {
            Invoke-Recyclarr
        }
    }
    'doctor' {
        Invoke-Doctor
    }
    'config' {
        Test-DockerEngine
        Test-RuntimeSecrets
        Test-VpnSecrets
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
        Test-RuntimeSecrets
        Test-VpnSecrets
        docker compose pull
        docker compose up -d
        docker image prune -f
    }
    'backup' {
        Test-DockerEngine
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        New-Item -ItemType Directory -Force -Path 'backups' | Out-Null
        docker compose stop
        tar -czf "backups/media-stack-$timestamp.tgz" config .env docker-compose.yml compose env indexers.example.json recyclarr.example.yml scripts stack.ps1 stack.sh readme.md
        docker compose up -d
        Write-Host "Backup written to backups/media-stack-$timestamp.tgz"
        Write-Host 'Treat this archive as sensitive: config/ can contain API keys and session tokens.'
    }
    'verify' {
        Test-DockerEngine
        Test-RuntimeSecrets
        Test-VpnSecrets
        $gluetunContainerId = (docker compose ps -q gluetun).Trim()
        if (-not $gluetunContainerId) {
            throw 'Gluetun is not running. Start the stack first with .\stack.ps1 up.'
        }

        $gluetunHealth = (docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $gluetunContainerId).Trim()
        if ($gluetunHealth -ne 'healthy') {
            docker compose logs --tail=40 gluetun
            throw "Gluetun is $gluetunHealth. Fix the tunnel first, then run verify again."
        }

        $exposedVpnEnvironment = docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $gluetunContainerId |
            Where-Object { $_ -match '^(OPENVPN_(USER|PASSWORD)|VPN_(USER|PASS))=.+' }
        if ($exposedVpnEnvironment) {
            throw 'FAIL: Gluetun has non-empty VPN credentials in its environment. Recreate it with compose\secrets.yml enabled.'
        }
        Write-Host 'PASS: Gluetun inspect data contains no VPN credential values.'

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
