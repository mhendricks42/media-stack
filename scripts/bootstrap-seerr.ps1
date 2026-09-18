########################################################################
# Configure Seerr with Sonarr/Radarr services and quality profiles
#
# This script:
# 1. Waits for Seerr to be healthy
# 2. Reads API keys from Sonarr/Radarr config files
# 3. Queries their APIs to find quality profile IDs
# 4. Updates Seerr's settings.json with the correct configuration
#
# Called from bootstrap.ps1 after Seerr is initialized.
########################################################################

param(
    [string]$SonarrExternalUrl = 'http://localhost:8989',
    [string]$RadarrExternalUrl = 'http://localhost:7878'
)

$ErrorActionPreference = 'Stop'

trap {
    Write-Host $_.Exception.Message
    exit 1
}

function Wait-SeerrHealthy {
    param([int]$TimeoutSeconds = 120)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri 'http://localhost:5055/api/v1/status' -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -eq 200) {
                Write-Host 'Seerr is healthy.'
                return
            }
        }
        catch {
        }
        Start-Sleep -Seconds 3
    }

    throw 'Seerr did not become healthy within timeout.'
}

function Get-ApiKeyFromConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Missing config file: $Path"
    }

    $xml = [xml](Get-Content $Path)
    $apiKey = [string]$xml.Config.ApiKey
    if (-not $apiKey) {
        throw "No ApiKey found in $Path."
    }

    return $apiKey
}

function Get-ArrQualityProfiles {
    param(
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$AppName
    )

    $headers = @{ 'X-Api-Key' = $ApiKey }
    try {
        $profiles = Invoke-RestMethod -Method GET -Uri "$BaseUrl/api/v3/qualityprofile" -Headers $headers -TimeoutSec 10
        return @($profiles | Sort-Object -Property id)
    }
    catch {
        throw "$AppName quality profile lookup failed: $_"
    }
}

function Find-ProfileId {
    param(
        [object[]]$Profiles,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $found = $Profiles | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if ($found) { return $found.id }
    }

    return $Profiles[0].id
}

function Set-JsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function New-SeerrApiKey {
    $bytes = New-Object byte[] 48
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
        return [Convert]::ToBase64String($bytes)
    }
    finally {
        $random.Dispose()
    }
}

function Ensure-SeerrApiKey {
    param([string]$SettingsPath)

    if (-not (Test-Path $SettingsPath)) {
        throw "Missing Seerr settings file: $SettingsPath"
    }

    $settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
    if (-not $settings.PSObject.Properties['main'] -or $null -eq $settings.main) {
        Set-JsonProperty -Object $settings -Name 'main' -Value ([pscustomobject]@{})
    }

    if ($settings.main.PSObject.Properties['apiKey'] -and -not [string]::IsNullOrWhiteSpace([string]$settings.main.apiKey)) {
        Write-Host 'Seerr API key verified.'
        return
    }

    Set-JsonProperty -Object $settings.main -Name 'apiKey' -Value (New-SeerrApiKey)
    Copy-Item $SettingsPath "$SettingsPath.bak" -Force
    $settings | ConvertTo-Json -Depth 30 | Set-Content $SettingsPath
    Write-Host "Seerr API key generated. Backup: $SettingsPath.bak"
}

function Update-SeerrSettings {
    param(
        [string]$SettingsPath,
        [string]$Service,
        [int]$ProfileId,
        [string]$ProfileName,
        [string]$ApiKey
    )

    if (-not (Test-Path $SettingsPath)) {
        throw "Missing Seerr settings file: $SettingsPath"
    }

    $settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json

    if ($Service -eq 'sonarr') {
        if ($settings.sonarr.Count -eq 0) {
            $settings.sonarr = @([pscustomobject]@{})
        }
        $instance = $settings.sonarr[0]
        Set-JsonProperty -Object $instance -Name 'name' -Value 'Sonarr'
        Set-JsonProperty -Object $instance -Name 'hostname' -Value 'sonarr'
        Set-JsonProperty -Object $instance -Name 'port' -Value 8989
        Set-JsonProperty -Object $instance -Name 'apiKey' -Value $ApiKey
        Set-JsonProperty -Object $instance -Name 'useSsl' -Value $false
        Set-JsonProperty -Object $instance -Name 'activeProfileId' -Value $ProfileId
        Set-JsonProperty -Object $instance -Name 'activeProfileName' -Value $ProfileName
        Set-JsonProperty -Object $instance -Name 'activeDirectory' -Value '/data/media/tv'
        Set-JsonProperty -Object $instance -Name 'activeAnimeProfileId' -Value $ProfileId
        Set-JsonProperty -Object $instance -Name 'activeAnimeProfileName' -Value $ProfileName
        Set-JsonProperty -Object $instance -Name 'activeAnimeDirectory' -Value '/data/media/tv'
        Set-JsonProperty -Object $instance -Name 'tags' -Value @()
        Set-JsonProperty -Object $instance -Name 'animeTags' -Value @()
        Set-JsonProperty -Object $instance -Name 'is4k' -Value $false
        Set-JsonProperty -Object $instance -Name 'isDefault' -Value $true
        Set-JsonProperty -Object $instance -Name 'enableSeasonFolders' -Value $true
        Set-JsonProperty -Object $instance -Name 'syncEnabled' -Value $true
        Set-JsonProperty -Object $instance -Name 'preventSearch' -Value $false
        Set-JsonProperty -Object $instance -Name 'tagRequests' -Value $false
        Set-JsonProperty -Object $instance -Name 'monitorNewItems' -Value 'all'
        Set-JsonProperty -Object $instance -Name 'id' -Value 0

        Write-Host "Updated Seerr Sonarr config: sonarr:8989, scans enabled, profile $ProfileId ($ProfileName)"
    }
    elseif ($Service -eq 'radarr') {
        if ($settings.radarr.Count -eq 0) {
            $settings.radarr = @([pscustomobject]@{})
        }
        $instance = $settings.radarr[0]
        Set-JsonProperty -Object $instance -Name 'name' -Value 'Radarr'
        Set-JsonProperty -Object $instance -Name 'hostname' -Value 'radarr'
        Set-JsonProperty -Object $instance -Name 'port' -Value 7878
        Set-JsonProperty -Object $instance -Name 'apiKey' -Value $ApiKey
        Set-JsonProperty -Object $instance -Name 'useSsl' -Value $false
        Set-JsonProperty -Object $instance -Name 'activeProfileId' -Value $ProfileId
        Set-JsonProperty -Object $instance -Name 'activeProfileName' -Value $ProfileName
        Set-JsonProperty -Object $instance -Name 'activeDirectory' -Value '/data/media/movies'
        Set-JsonProperty -Object $instance -Name 'is4k' -Value $false
        Set-JsonProperty -Object $instance -Name 'minimumAvailability' -Value 'released'
        Set-JsonProperty -Object $instance -Name 'tags' -Value @()
        Set-JsonProperty -Object $instance -Name 'isDefault' -Value $true
        Set-JsonProperty -Object $instance -Name 'syncEnabled' -Value $true
        Set-JsonProperty -Object $instance -Name 'preventSearch' -Value $false
        Set-JsonProperty -Object $instance -Name 'tagRequests' -Value $false
        Set-JsonProperty -Object $instance -Name 'id' -Value 0

        Write-Host "Updated Seerr Radarr config: radarr:7878, scans enabled, profile $ProfileId ($ProfileName)"
    }

    # Backup and write
    Copy-Item $SettingsPath "$SettingsPath.bak" -Force
    $settings | ConvertTo-Json -Depth 30 | Set-Content $SettingsPath

    Write-Host "Seerr settings updated. Backup: $SettingsPath.bak"
}

Write-Host 'Configuring Seerr with Sonarr and Radarr...'

Wait-SeerrHealthy
Ensure-SeerrApiKey -SettingsPath '.\config\seerr\settings.json'

$sonarrApiKey = Get-ApiKeyFromConfig '.\config\sonarr\config.xml'
$radarrApiKey = Get-ApiKeyFromConfig '.\config\radarr\config.xml'

Write-Host 'Fetching quality profiles from Sonarr...'
$sonarrProfiles = Get-ArrQualityProfiles -BaseUrl $SonarrExternalUrl -ApiKey $sonarrApiKey -AppName 'Sonarr'
$sonarrProfileId = Find-ProfileId -Profiles $sonarrProfiles -Names @('WEB-1080p', 'HD-1080p', '[Anime] Remux-1080p')
$sonarrProfileName = ($sonarrProfiles | Where-Object { $_.id -eq $sonarrProfileId }).name

echo "Fetching quality profiles from Radarr..."
$radarrProfiles = Get-ArrQualityProfiles -BaseUrl $RadarrExternalUrl -ApiKey $radarrApiKey -AppName 'Radarr'
$radarrProfileId = Find-ProfileId -Profiles $radarrProfiles -Names @('HD Bluray + WEB', 'HD-1080p', 'Remux-1080p')
$radarrProfileName = ($radarrProfiles | Where-Object { $_.id -eq $radarrProfileId }).name

Update-SeerrSettings -SettingsPath '.\config\seerr\settings.json' -Service 'sonarr' -ProfileId $sonarrProfileId -ProfileName $sonarrProfileName -ApiKey $sonarrApiKey
Update-SeerrSettings -SettingsPath '.\config\seerr\settings.json' -Service 'radarr' -ProfileId $radarrProfileId -ProfileName $radarrProfileName -ApiKey $radarrApiKey

Write-Host 'Seerr bootstrap complete. Restart Seerr to reload settings:'
Write-Host '  docker compose restart seerr'
