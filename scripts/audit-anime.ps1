$ErrorActionPreference = 'Stop'

$sonarrUrl = if ($env:SONARR_URL) { $env:SONARR_URL } else { 'http://localhost:8989' }
$jellyfinUrl = if ($env:JELLYFIN_URL) { $env:JELLYFIN_URL } else { 'http://localhost:8096' }
$configPath = '.\config\sonarr\config.xml'
$seerrSettingsPath = '.\config\seerr\settings.json'

if (-not (Test-Path $configPath)) {
    throw "Missing $configPath"
}
$apiKey = [string]([xml](Get-Content $configPath)).Config.ApiKey
if (-not $apiKey) {
    throw "Sonarr API key is missing from $configPath"
}
if (-not $env:JELLYFIN_USER -or -not $env:JELLYFIN_PASS) {
    throw 'JELLYFIN_USER and JELLYFIN_PASS are required to audit the Anime library.'
}
$headers = @{ 'X-Api-Key' = $apiKey }

$rootFolders = @(Invoke-RestMethod -Method GET -Uri "$sonarrUrl/api/v3/rootfolder" -Headers $headers -TimeoutSec 10)
if (-not ($rootFolders | Where-Object { $_.path -eq '/data/media/anime' })) {
    throw 'Sonarr anime root folder is missing.'
}
Write-Host 'PASS: Sonarr anime root folder'

$naming = Invoke-RestMethod -Method GET -Uri "$sonarrUrl/api/v3/config/naming" -Headers $headers -TimeoutSec 10
if (-not ([string]$naming.animeEpisodeFormat).Contains('{absolute')) {
    throw 'Sonarr anime episode format does not contain an absolute-number token.'
}
Write-Host 'PASS: Sonarr anime absolute-number naming'

$mismatches = @(
    Invoke-RestMethod -Method GET -Uri "$sonarrUrl/api/v3/series" -Headers $headers -TimeoutSec 10 |
        Where-Object { ([string]$_.path).StartsWith('/data/media/anime/') -and $_.seriesType -ne 'anime' }
)
if ($mismatches.Count -gt 0) {
    $details = $mismatches | ForEach-Object { "$($_.title) [$($_.id)] type=$($_.seriesType)" }
    throw "Series under the anime root are not typed as anime:`n$($details -join "`n")`nRun bootstrap to reconcile root-based series types."
}
Write-Host 'PASS: Sonarr series under the anime root use seriesType=anime'

if (-not (Test-Path $seerrSettingsPath)) {
    throw "Missing $seerrSettingsPath"
}
$settings = Get-Content $seerrSettingsPath -Raw | ConvertFrom-Json
$sonarr = @($settings.sonarr)[0]
if ($sonarr.activeAnimeDirectory -ne '/data/media/anime' -or -not ([string]$sonarr.activeAnimeProfileName).StartsWith('[Anime]')) {
    throw 'Seerr anime root/profile override is not configured.'
}
Write-Host 'PASS: Seerr anime root and quality profile'

$clientAuthorization = 'MediaBrowser Client="media-stack", Device="anime-audit", DeviceId="media-stack-anime-audit", Version="1.0"'
$session = Invoke-RestMethod -Method POST -Uri "$jellyfinUrl/Users/AuthenticateByName" `
    -Headers @{ Authorization = $clientAuthorization } `
    -ContentType 'application/json' `
    -Body (@{ Username = $env:JELLYFIN_USER; Pw = $env:JELLYFIN_PASS } | ConvertTo-Json) `
    -TimeoutSec 10
if (-not $session.AccessToken) {
    throw 'Jellyfin authentication returned no access token.'
}
$tokenAuthorization = "MediaBrowser Token=`"$($session.AccessToken)`", Client=`"media-stack`", Device=`"anime-audit`", DeviceId=`"media-stack-anime-audit`", Version=`"1.0`""
$libraries = @(Invoke-RestMethod -Method GET -Uri "$jellyfinUrl/Library/VirtualFolders" -Headers @{ Authorization = $tokenAuthorization } -TimeoutSec 10)
$animeLibrary = $libraries | Where-Object { $_.Name -eq 'Anime' -and @($_.Locations) -contains '/data/media/anime' } | Select-Object -First 1
if (-not $animeLibrary) {
    throw 'Jellyfin Anime library is missing /data/media/anime.'
}
Write-Host 'PASS: Jellyfin Anime library path'
Write-Host 'Anime automation baseline verified.'
