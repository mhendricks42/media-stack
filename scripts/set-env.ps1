param(
    [switch]$IncludeTailscale,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Read-Value {
    param(
        [string]$Name,
        [string]$Prompt,
        [string]$Default = '',
        [switch]$Required
    )

    $existing = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($existing -and -not $Force) {
        Write-Host "$Name is already set; keeping existing value. Use -Force to replace it."
        return $existing
    }

    $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    while ($true) {
        $value = Read-Host $label
        if (-not $value -and $Default) { $value = $Default }
        if ($value -or -not $Required) { return $value }
        Write-Host "$Name is required."
    }
}

function Read-SecretValue {
    param(
        [string]$Name,
        [string]$Prompt,
        [int]$MinLength = 1
    )

    $existing = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($existing -and -not $Force) {
        Write-Host "$Name is already set; keeping existing value. Use -Force to replace it."
        return $existing
    }

    while ($true) {
        $secure = Read-Host $Prompt -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        if ($value.Length -ge $MinLength) { return $value }
        Write-Host "$Name must be at least $MinLength character(s)."
    }
}

function Set-SessionEnv {
    param([string]$Name, [string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

Write-Host 'This wizard sets secrets only for this PowerShell session.'
Write-Host 'Close this terminal to clear them, or overwrite them with -Force.'
Write-Host ''

Set-SessionEnv 'NORD_USER' (Read-Value 'NORD_USER' 'NordVPN OpenVPN/manual username' -Required)
Set-SessionEnv 'NORD_PASS' (Read-SecretValue 'NORD_PASS' 'NordVPN OpenVPN/manual password')

Set-SessionEnv 'QBIT_USER' (Read-Value 'QBIT_USER' 'qBittorrent Web UI username' 'admin' -Required)
Set-SessionEnv 'QBIT_PASS' (Read-SecretValue 'QBIT_PASS' 'qBittorrent Web UI password' 6)

Set-SessionEnv 'SABNZBD_USER' (Read-Value 'SABNZBD_USER' 'SABnzbd Web UI username' 'admin' -Required)
Set-SessionEnv 'SABNZBD_PASS' (Read-SecretValue 'SABNZBD_PASS' 'SABnzbd Web UI password' 6)

$sabServerHost = Read-Value 'SAB_SERVER_HOST' 'Primary Usenet server host (blank to skip)' ''
if ($sabServerHost) {
    Set-SessionEnv 'SAB_SERVER_HOST' $sabServerHost
    Set-SessionEnv 'SAB_SERVER_USER' (Read-Value 'SAB_SERVER_USER' 'Primary Usenet server username' '' -Required)
    Set-SessionEnv 'SAB_SERVER_PASS' (Read-SecretValue 'SAB_SERVER_PASS' 'Primary Usenet server password')
    Set-SessionEnv 'SAB_SERVER_PORT' (Read-Value 'SAB_SERVER_PORT' 'Primary Usenet server port' '563' -Required)
    Set-SessionEnv 'SAB_SERVER_CONNECTIONS' (Read-Value 'SAB_SERVER_CONNECTIONS' 'Primary Usenet server connections' '20' -Required)
}

$sabBackupServerHost = Read-Value 'SAB_BACKUP_SERVER_HOST' 'Backup/block Usenet server host (blank to skip)' ''
if ($sabBackupServerHost) {
    Set-SessionEnv 'SAB_BACKUP_SERVER_HOST' $sabBackupServerHost
    Set-SessionEnv 'SAB_BACKUP_SERVER_USER' (Read-Value 'SAB_BACKUP_SERVER_USER' 'Backup/block Usenet server username' '' -Required)
    Set-SessionEnv 'SAB_BACKUP_SERVER_PASS' (Read-SecretValue 'SAB_BACKUP_SERVER_PASS' 'Backup/block Usenet server password')
    Set-SessionEnv 'SAB_BACKUP_SERVER_PORT' (Read-Value 'SAB_BACKUP_SERVER_PORT' 'Backup/block Usenet server port' '563' -Required)
    Set-SessionEnv 'SAB_BACKUP_SERVER_CONNECTIONS' (Read-Value 'SAB_BACKUP_SERVER_CONNECTIONS' 'Backup/block Usenet server connections' '10' -Required)
}

Set-SessionEnv 'SONARR_USER' (Read-Value 'SONARR_USER' 'Sonarr UI username' 'admin' -Required)
Set-SessionEnv 'SONARR_PASS' (Read-SecretValue 'SONARR_PASS' 'Sonarr UI password' 6)

Set-SessionEnv 'RADARR_USER' (Read-Value 'RADARR_USER' 'Radarr UI username' 'admin' -Required)
Set-SessionEnv 'RADARR_PASS' (Read-SecretValue 'RADARR_PASS' 'Radarr UI password' 6)

Set-SessionEnv 'PROWLARR_USER' (Read-Value 'PROWLARR_USER' 'Prowlarr UI username' 'admin' -Required)
Set-SessionEnv 'PROWLARR_PASS' (Read-SecretValue 'PROWLARR_PASS' 'Prowlarr UI password' 6)

Set-SessionEnv 'BAZARR_USER' (Read-Value 'BAZARR_USER' 'Bazarr UI username' 'admin' -Required)
Set-SessionEnv 'BAZARR_PASS' (Read-SecretValue 'BAZARR_PASS' 'Bazarr UI password' 6)

Set-SessionEnv 'JELLYFIN_USER' (Read-Value 'JELLYFIN_USER' 'Jellyfin administrator username' 'admin' -Required)
Set-SessionEnv 'JELLYFIN_PASS' (Read-SecretValue 'JELLYFIN_PASS' 'Jellyfin administrator password' 6)

Set-SessionEnv 'SEERR_EMAIL' (Read-Value 'SEERR_EMAIL' 'Seerr administrator email' 'admin@example.invalid' -Required)

if ($IncludeTailscale) {
    Set-SessionEnv 'TS_AUTHKEY' (Read-SecretValue 'TS_AUTHKEY' 'Tailscale auth key')
}

Write-Host ''
Write-Host 'Session environment variables set.'
Write-Host 'Next: .\stack.ps1 bootstrap'
