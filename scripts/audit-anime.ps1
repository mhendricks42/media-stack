$ErrorActionPreference = 'Stop'

$sonarrUrl = if ($env:SONARR_URL) { $env:SONARR_URL } else { 'http://localhost:8989' }
$configPath = '.\config\sonarr\config.xml'
$seerrSettingsPath = '.\config\seerr\settings.json'

if (-not (Test-Path $configPath)) {
    throw "Missing $configPath"
}
$apiKey = [string]([xml](Get-Content $configPath)).Config.ApiKey
if (-not $apiKey) {
    throw "Sonarr API key is missing from $configPath"
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
Write-Host 'Anime automation baseline verified.'
