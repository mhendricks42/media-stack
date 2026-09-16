param(
    [string]$Distro = 'Ubuntu',
    [string]$LinuxUser = '',
    [string]$DataDirectory = 'data'
)

$ErrorActionPreference = 'Stop'

function Get-WslDistributions {
    $raw = & wsl.exe -l -q 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }

    return $raw |
        ForEach-Object { ($_ -replace "`0", '').Trim() } |
        Where-Object { $_ }
}

function Invoke-WslShell {
    param(
        [string]$DistroName,
        [string]$Command
    )

    & wsl.exe -d $DistroName -- sh -lc $Command
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed in $DistroName`: $Command"
    }
}

function Set-DotEnvValue {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Value
    )

    $line = "$Name=$Value"
    if (-not (Test-Path $Path)) {
        Set-Content -Path $Path -Value $line
        return
    }

    $lines = @(Get-Content $Path)
    $updated = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match "^$([regex]::Escape($Name))=") {
            $lines[$index] = $line
            $updated = $true
            break
        }
    }

    if (-not $updated) { $lines += $line }
    Set-Content -Path $Path -Value $lines
}

function Test-CommandAvailable {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was not found. Install it, reopen PowerShell, then run this command again."
    }
}

if ($DataDirectory -match '[\\/:]' -or -not $DataDirectory.Trim()) {
    throw 'DataDirectory must be a simple folder name such as data.'
}

Test-CommandAvailable 'wsl.exe'
Test-CommandAvailable 'docker.exe'

$distros = @(Get-WslDistributions)
if ($distros -notcontains $Distro) {
    Write-Host "Installing WSL distro: $Distro"
    & wsl.exe --install -d $Distro
    throw "Finish the first-launch setup for $Distro, then rerun: .\stack.ps1 init-windows $Distro"
}

if (-not $LinuxUser) {
    $LinuxUser = (& wsl.exe -d $Distro -- sh -lc 'id -un').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $LinuxUser) {
        throw "Could not determine the default user for $Distro. Pass it explicitly: .\stack.ps1 init-windows $Distro <user>"
    }
}

if ($LinuxUser -eq 'root') {
    throw "The default user for $Distro is root. Use a normal WSL user or pass one explicitly: .\stack.ps1 init-windows $Distro <user>"
}

$linuxDataRoot = "/home/$LinuxUser/$DataDirectory"
$windowsDataRoot = "\\wsl`$\$Distro\home\$LinuxUser\$DataDirectory"

Write-Host "Using WSL distro: $Distro"
Write-Host "Using WSL user:   $LinuxUser"
Write-Host "Data root:        $windowsDataRoot"

Invoke-WslShell $Distro "mkdir -p '$linuxDataRoot/torrents/incomplete' '$linuxDataRoot/media/tv' '$linuxDataRoot/media/movies'"

if (-not (Test-Path '.env')) {
    Copy-Item 'env\windows.env.example' '.env'
    Write-Host 'Created .env from env\windows.env.example'
}

$linuxId = (& wsl.exe -d $Distro -- sh -lc "id -u '$LinuxUser'; id -g '$LinuxUser'")
if ($LASTEXITCODE -ne 0 -or $linuxId.Count -lt 2) {
    throw "Could not read uid/gid for $LinuxUser in $Distro."
}

Set-DotEnvValue '.env' 'COMPOSE_PROJECT_NAME' 'media-dev'
Set-DotEnvValue '.env' 'COMPOSE_FILE' 'docker-compose.yml;compose/windows.yml'
Set-DotEnvValue '.env' 'COMPOSE_PATH_SEPARATOR' ';'
Set-DotEnvValue '.env' 'COMPOSE_PROFILES' 'tailscale'
Set-DotEnvValue '.env' 'BIND_ADDR' '127.0.0.1'
Set-DotEnvValue '.env' 'RESTART_POLICY' 'no'
Set-DotEnvValue '.env' 'PUID' $linuxId[0].Trim()
Set-DotEnvValue '.env' 'PGID' $linuxId[1].Trim()
Set-DotEnvValue '.env' 'DATA_ROOT' $windowsDataRoot
Set-DotEnvValue '.env' 'TS_HOSTNAME' 'media-dev-windows'

Write-Host 'Updated .env for Windows development.'

& docker.exe info --format '{{.ServerVersion}}' *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker engine is not reachable. Start Docker Desktop and wait until it says Running.'
}

& docker.exe run --rm -v "${windowsDataRoot}:/mnt/data" alpine:3.20 sh -lc 'test -d /mnt/data/torrents/incomplete -a -d /mnt/data/media/tv -a -d /mnt/data/media/movies' *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker cannot mount $windowsDataRoot. In Docker Desktop, enable Settings > Resources > WSL Integration > $Distro, click Apply and Restart, then rerun this command."
}

Write-Host 'Docker WSL mount test passed.'
Write-Host 'Next: .\stack.ps1 env --force; .\stack.ps1 up'