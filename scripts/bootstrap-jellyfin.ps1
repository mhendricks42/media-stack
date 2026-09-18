param(
    [string]$JellyfinUsername = $env:JELLYFIN_USER,
    [string]$JellyfinPassword = $env:JELLYFIN_PASS,
    [string]$JellyfinServerName = $env:JELLYFIN_SERVER_NAME,
    [string]$MoviesLibraryName = 'Movies',
    [string]$MoviesLibraryPath = '/data/media/movies',
    [string]$ShowsLibraryName = 'Shows',
    [string]$ShowsLibraryPath = '/data/media/tv',
    [string]$LiveTvTunerUrl = 'http://ersatztv:8409/iptv/channels.m3u',
    [string]$LiveTvGuideUrl = 'http://ersatztv:8409/iptv/xmltv.xml'
)

$ErrorActionPreference = 'Stop'

trap {
    Write-Host $_.Exception.Message
    exit 1
}

function Get-EnvFileValue {
    param(
        [string]$Name,
        [string]$Default = ''
    )

    if (-not (Test-Path '.env')) { return $Default }
    $line = Get-Content '.env' | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -First 1
    if (-not $line) { return $Default }
    $value = $line -replace "^$([regex]::Escape($Name))=", ''
    return $value.Trim().Trim('"').Trim("'")
}

function Invoke-JsonRequest {
    param(
        [ValidateSet('GET', 'POST', 'PUT')]
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers = @{},
        [object]$Body = $null
    )

    $parameters = @{ Method = $Method; Uri = $Uri; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 20 }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 40))
    }

    try {
        $response = Invoke-WebRequest @parameters
    }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'unknown' }
        $detail = ''
        if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream()) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $detail = $reader.ReadToEnd()
            $detail = $detail -replace '(?i)("(?:password|pass|apikey|token|secret|cookie)"\s*:\s*")[^"]+', '$1<redacted>'
        }
        throw "API $Method $Uri failed with status $status. $detail"
    }

    $content = if ($response.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
    if ([string]::IsNullOrWhiteSpace($content)) { return $null }
    return $content | ConvertFrom-Json
}

function Get-JellyfinBootstrapHeaders {
    return @{ Authorization = 'MediaBrowser Client="media-stack", Device="bootstrap", DeviceId="media-stack-bootstrap", Version="1.0"' }
}

function Get-JellyfinSession {
    if ([string]::IsNullOrWhiteSpace($JellyfinUsername) -or [string]::IsNullOrWhiteSpace($JellyfinPassword)) {
        throw 'JELLYFIN_USER and JELLYFIN_PASS are required for Jellyfin bootstrap.'
    }

    return Invoke-JsonRequest -Method POST -Uri 'http://localhost:8096/Users/AuthenticateByName' `
        -Headers (Get-JellyfinBootstrapHeaders) `
        -Body @{ Username = $JellyfinUsername; Pw = $JellyfinPassword }
}

function Get-JellyfinTokenHeaders {
    param([string]$AccessToken)

    return @{ Authorization = "MediaBrowser Token=`"$AccessToken`", Client=`"media-stack`", Device=`"bootstrap`", DeviceId=`"media-stack-bootstrap`", Version=`"1.0`"" }
}

function Ensure-JellyfinServerName {
    param([hashtable]$Headers)

    $config = Invoke-JsonRequest -Method GET -Uri 'http://localhost:8096/System/Configuration' -Headers $Headers
    if ($config.ServerName -eq $JellyfinServerName) {
        Write-Host "Jellyfin server name verified: $JellyfinServerName"
        return
    }

    $config.ServerName = $JellyfinServerName
    Invoke-JsonRequest -Method POST -Uri 'http://localhost:8096/System/Configuration' -Headers $Headers -Body $config | Out-Null
    Write-Host "Jellyfin server name configured: $JellyfinServerName"
}

function New-JellyfinLibraryOptions {
    param(
        [string]$CollectionType,
        [string]$Path
    )

    $typeOptions = if ($CollectionType -eq 'movies') {
        @(
            @{
                Type = 'Movie'
                MetadataFetchers = @('TheMovieDb', 'The Open Movie Database')
                MetadataFetcherOrder = @('TheMovieDb', 'The Open Movie Database')
                ImageFetchers = @('TheMovieDb', 'The Open Movie Database', 'Embedded Image Extractor', 'Screen Grabber')
                ImageFetcherOrder = @('TheMovieDb', 'The Open Movie Database', 'Embedded Image Extractor', 'Screen Grabber')
                ImageOptions = @()
                SimilarItemProviders = @('Local Genre/Tag')
                SimilarItemProviderOrder = @('TheMovieDb', 'Local Genre/Tag')
            }
        )
    }
    else {
        @(
            @{
                Type = 'Series'
                MetadataFetchers = @('TheMovieDb', 'The Open Movie Database')
                MetadataFetcherOrder = @('TheMovieDb', 'The Open Movie Database')
                ImageFetchers = @('TheMovieDb')
                ImageFetcherOrder = @('TheMovieDb')
                ImageOptions = @()
                SimilarItemProviders = @('Local Genre/Tag')
                SimilarItemProviderOrder = @('TheMovieDb', 'Local Genre/Tag')
            },
            @{
                Type = 'Season'
                MetadataFetchers = @('TheMovieDb')
                MetadataFetcherOrder = @('TheMovieDb')
                ImageFetchers = @('TheMovieDb')
                ImageFetcherOrder = @('TheMovieDb')
                ImageOptions = @()
                SimilarItemProviders = @()
                SimilarItemProviderOrder = @()
            },
            @{
                Type = 'Episode'
                MetadataFetchers = @('TheMovieDb', 'The Open Movie Database')
                MetadataFetcherOrder = @('TheMovieDb', 'The Open Movie Database')
                ImageFetchers = @('TheMovieDb', 'The Open Movie Database', 'Embedded Image Extractor', 'Screen Grabber')
                ImageFetcherOrder = @('TheMovieDb', 'The Open Movie Database', 'Embedded Image Extractor', 'Screen Grabber')
                ImageOptions = @()
                SimilarItemProviders = @()
                SimilarItemProviderOrder = @()
            }
        )
    }

    return @{
        Enabled = $true
        EnablePhotos = $true
        EnableRealtimeMonitor = $true
        EnableLUFSScan = $true
        EnableChapterImageExtraction = $false
        ExtractChapterImagesDuringLibraryScan = $false
        EnableTrickplayImageExtraction = $false
        ExtractTrickplayImagesDuringLibraryScan = $false
        PathInfos = @(@{ Path = $Path })
        SaveLocalMetadata = $false
        EnableInternetProviders = $true
        EnableAutomaticSeriesGrouping = $false
        EnableEmbeddedTitles = $false
        EnableEmbeddedExtrasTitles = $false
        EnableEmbeddedEpisodeInfos = $false
        AutomaticRefreshIntervalDays = 0
        PreferredMetadataLanguage = ''
        MetadataCountryCode = ''
        SeasonZeroDisplayName = 'Specials'
        MetadataSavers = @()
        DisabledLocalMetadataReaders = @()
        LocalMetadataReaderOrder = @('Nfo')
        DisabledSubtitleFetchers = @()
        SubtitleFetcherOrder = @()
        DisabledMediaSegmentProviders = @()
        MediaSegmentProviderOrder = @()
        SkipSubtitlesIfEmbeddedSubtitlesPresent = $false
        SkipSubtitlesIfAudioTrackMatches = $false
        SubtitleDownloadLanguages = @()
        RequirePerfectSubtitleMatch = $true
        SaveSubtitlesWithMedia = $true
        DisabledLyricFetchers = @()
        LyricFetcherOrder = @()
        CustomTagDelimiters = @('/', '|', ';', '\')
        DelimiterWhitelist = @()
        AutomaticallyAddToCollection = $false
        AllowEmbeddedSubtitles = 'AllowAll'
        TypeOptions = $typeOptions
    }
}

function Ensure-JellyfinLibrary {
    param(
        [hashtable]$Headers,
        [string]$Name,
        [string]$CollectionType,
        [string]$Path
    )

    $libraries = @(Invoke-JsonRequest -Method GET -Uri 'http://localhost:8096/Library/VirtualFolders' -Headers $Headers)
    $existing = @($libraries | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
    if ($existing.Count -gt 0) {
        $locations = @($existing[0].Locations)
        if ($locations -contains $Path) {
            Write-Host "Jellyfin library verified: $Name -> $Path"
            return
        }

        Invoke-JsonRequest -Method POST -Uri "http://localhost:8096/Library/VirtualFolders/Paths?name=$([uri]::EscapeDataString($Name))" `
            -Headers $Headers `
            -Body @{ Name = $Name; Path = $Path } | Out-Null
        Write-Host "Jellyfin library path added: $Name -> $Path"
        return
    }

    $options = New-JellyfinLibraryOptions -CollectionType $CollectionType -Path $Path
    Invoke-JsonRequest -Method POST -Uri "http://localhost:8096/Library/VirtualFolders?name=$([uri]::EscapeDataString($Name))&collectionType=$([uri]::EscapeDataString($CollectionType))&refreshLibrary=false" `
        -Headers $Headers `
        -Body $options | Out-Null
    Write-Host "Jellyfin library created: $Name -> $Path"
}

function Ensure-XmlElementValue {
    param(
        [xml]$Xml,
        [System.Xml.XmlElement]$Parent,
        [string]$Name,
        [string]$Value
    )

    $element = $Parent[$Name]
    if (-not $element) {
        $element = $Xml.CreateElement($Name)
        $Parent.AppendChild($element) | Out-Null
    }
    $element.InnerText = $Value
}

function Ensure-XmlElementBool {
    param(
        [xml]$Xml,
        [System.Xml.XmlElement]$Parent,
        [string]$Name,
        [bool]$Value
    )

    Ensure-XmlElementValue -Xml $Xml -Parent $Parent -Name $Name -Value $(if ($Value) { 'true' } else { 'false' })
}

function Ensure-JellyfinLiveTvConfig {
    $configPath = '.\config\jellyfin\livetv.xml'
    if (Test-Path $configPath) {
        $original = Get-Content -Raw $configPath
        [xml]$xml = $original
    }
    else {
        $xml = New-Object System.Xml.XmlDocument
        $declaration = $xml.CreateXmlDeclaration('1.0', 'utf-8', $null)
        $xml.AppendChild($declaration) | Out-Null
        $rootNode = $xml.CreateElement('LiveTvOptions')
        $xml.AppendChild($rootNode) | Out-Null
        $original = ''
    }

    $root = $xml.DocumentElement

    $tunerHosts = $root.SelectSingleNode('TunerHosts')
    if ($null -eq $tunerHosts) {
        $tunerHosts = $xml.CreateElement('TunerHosts')
        $root.AppendChild($tunerHosts) | Out-Null
    }

    $listingProviders = $root.SelectSingleNode('ListingProviders')
    if ($null -eq $listingProviders) {
        $listingProviders = $xml.CreateElement('ListingProviders')
        $root.AppendChild($listingProviders) | Out-Null
    }

    $tuner = @($tunerHosts.SelectNodes('TunerHostInfo') | Where-Object { $_.Url -eq $LiveTvTunerUrl } | Select-Object -First 1)
    if ($tuner.Count -eq 0) {
        $tunerNode = $xml.CreateElement('TunerHostInfo')
        $tunerHosts.AppendChild($tunerNode) | Out-Null
        Ensure-XmlElementValue -Xml $xml -Parent $tunerNode -Name 'Id' -Value ([guid]::NewGuid().ToString('N'))
        $tuner = @($tunerNode)
    }
    $tunerNode = [System.Xml.XmlElement]$tuner[0]
    Ensure-XmlElementValue -Xml $xml -Parent $tunerNode -Name 'Url' -Value $LiveTvTunerUrl
    Ensure-XmlElementValue -Xml $xml -Parent $tunerNode -Name 'Type' -Value 'm3u'
    Ensure-XmlElementBool -Xml $xml -Parent $tunerNode -Name 'ImportFavoritesOnly' -Value $false
    Ensure-XmlElementBool -Xml $xml -Parent $tunerNode -Name 'AllowHWTranscoding' -Value $false
    Ensure-XmlElementBool -Xml $xml -Parent $tunerNode -Name 'AllowFmp4TranscodingContainer' -Value $false
    Ensure-XmlElementBool -Xml $xml -Parent $tunerNode -Name 'AllowStreamSharing' -Value $true
    Ensure-XmlElementValue -Xml $xml -Parent $tunerNode -Name 'FallbackMaxStreamingBitrate' -Value '30000000'
    Ensure-XmlElementBool -Xml $xml -Parent $tunerNode -Name 'EnableStreamLooping' -Value $false
    Ensure-XmlElementValue -Xml $xml -Parent $tunerNode -Name 'TunerCount' -Value '0'
    Ensure-XmlElementBool -Xml $xml -Parent $tunerNode -Name 'IgnoreDts' -Value $true
    Ensure-XmlElementBool -Xml $xml -Parent $tunerNode -Name 'ReadAtNativeFramerate' -Value $true

    $provider = @($listingProviders.SelectNodes('ListingsProviderInfo') | Where-Object { $_.Path -eq $LiveTvGuideUrl } | Select-Object -First 1)
    if ($provider.Count -eq 0) {
        $providerNode = $xml.CreateElement('ListingsProviderInfo')
        $listingProviders.AppendChild($providerNode) | Out-Null
        Ensure-XmlElementValue -Xml $xml -Parent $providerNode -Name 'Id' -Value ([guid]::NewGuid().ToString('N'))
        $provider = @($providerNode)
    }
    $providerNode = [System.Xml.XmlElement]$provider[0]
    Ensure-XmlElementValue -Xml $xml -Parent $providerNode -Name 'Type' -Value 'xmltv'
    Ensure-XmlElementValue -Xml $xml -Parent $providerNode -Name 'Path' -Value $LiveTvGuideUrl
    Ensure-XmlElementBool -Xml $xml -Parent $providerNode -Name 'EnableAllTuners' -Value $true

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UnicodeEncoding($false, $true)
    $settings.Indent = $true
    $settings.OmitXmlDeclaration = $false
    $builder = New-Object System.Text.StringBuilder
    $writer = [System.Xml.XmlWriter]::Create($builder, $settings)
    try { $xml.Save($writer) } finally { $writer.Dispose() }
    $updated = $builder.ToString() -replace '<\?xml version="1\.0" encoding="[^"]*"\?>', '<?xml version="1.0" encoding="utf-16"?>'

    if ($updated -eq $original) {
        Write-Host 'Jellyfin Live TV tuner and guide verified.'
        return $false
    }

    $fullConfigPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $configPath))
    [System.IO.File]::WriteAllText($fullConfigPath, $updated, (New-Object System.Text.UnicodeEncoding($false, $true)))
    Write-Host 'Jellyfin Live TV tuner and guide configured.'
    return $true
}

function Invoke-DockerComposeQuiet {
    param([string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & docker compose @Arguments 2>&1 | Out-Null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "docker compose $($Arguments -join ' ') failed with exit code $exitCode."
    }
}

function Wait-JellyfinWebUi {
    $lastError = ''
    for ($attempt = 1; $attempt -le 90; $attempt++) {
        try {
            Invoke-WebRequest -Uri 'http://localhost:8096/System/Info/Public' -UseBasicParsing -TimeoutSec 5 | Out-Null
            return
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 1
        }
    }

    throw "Jellyfin did not become ready within 90 seconds. Last error: $lastError"
}

Write-Host 'Configuring Jellyfin server baseline...'
if ([string]::IsNullOrWhiteSpace($JellyfinServerName)) {
    $JellyfinServerName = Get-EnvFileValue -Name 'JELLYFIN_SERVER_NAME' -Default 'Media Stack'
}

$session = Get-JellyfinSession
$headers = Get-JellyfinTokenHeaders -AccessToken $session.AccessToken

Ensure-JellyfinServerName -Headers $headers
Ensure-JellyfinLibrary -Headers $headers -Name $MoviesLibraryName -CollectionType 'movies' -Path $MoviesLibraryPath
Ensure-JellyfinLibrary -Headers $headers -Name $ShowsLibraryName -CollectionType 'tvshows' -Path $ShowsLibraryPath
$liveTvChanged = Ensure-JellyfinLiveTvConfig

if ($liveTvChanged) {
    Invoke-DockerComposeQuiet -Arguments @('restart', 'jellyfin')
    Wait-JellyfinWebUi
    Write-Host 'Jellyfin restarted to load Live TV baseline.'
}

Write-Host 'Jellyfin baseline complete.'
