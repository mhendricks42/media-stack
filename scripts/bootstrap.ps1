param(
    [string]$QbitUsername = $env:QBIT_USER,
    [string]$QbitPassword = $env:QBIT_PASS,
    [string]$ProwlarrExternalUrl = 'http://localhost:9696',
    [string]$SonarrExternalUrl = 'http://localhost:8989',
    [string]$RadarrExternalUrl = 'http://localhost:7878',
    [string]$ProwlarrInternalUrl = 'http://prowlarr:9696',
    [string]$SonarrInternalUrl = 'http://sonarr:8989',
    [string]$RadarrInternalUrl = 'http://radarr:7878',
    [string]$QbitInternalHost = 'gluetun',
    [int]$QbitInternalPort = 8080,
    [string]$TvCategory = 'tv',
    [string]$MovieCategory = 'movies',
    [int[]]$SonarrSyncCategories = @(5000),
    [int[]]$SonarrAnimeSyncCategories = @(5070),
    [int[]]$RadarrSyncCategories = @(2000),
    [string]$TvRootFolder = '/data/media/tv',
    [string]$MovieRootFolder = '/data/media/movies'
)

$ErrorActionPreference = 'Stop'

trap {
    Write-Host $_.Exception.Message
    exit 1
}

function Test-BootstrapEnvironment {
    $required = @(
        'QBIT_PASS',
        'SONARR_USER', 'SONARR_PASS',
        'RADARR_USER', 'RADARR_PASS',
        'PROWLARR_USER', 'PROWLARR_PASS',
        'BAZARR_USER', 'BAZARR_PASS',
        'JELLYFIN_USER', 'JELLYFIN_PASS',
        'SEERR_EMAIL'
    )
    $missing = @($required | Where-Object { -not [Environment]::GetEnvironmentVariable($_, 'Process') })
    if ($missing.Count -gt 0) {
        throw "Missing bootstrap environment variable(s): $($missing -join ', '). Run .\stack.ps1 env in this PowerShell session, then rerun bootstrap."
    }
}

function Get-ApiKeyFromConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Missing config file: $Path. Start the stack once before bootstrap."
    }

    $xml = [xml](Get-Content $Path)
    $apiKey = [string]$xml.Config.ApiKey
    if (-not $apiKey) {
        throw "No ApiKey found in $Path."
    }

    return $apiKey
}

function Invoke-ArrApi {
    param(
        [ValidateSet('GET', 'POST', 'PUT')]
        [string]$Method,
        [string]$Uri,
        [string]$ApiKey,
        [object]$Body = $null
    )

    $headers = @{ 'X-Api-Key' = $ApiKey }
    try {
        if ($null -eq $Body) {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
        }

        $json = ConvertTo-Json -InputObject $Body -Depth 30
        $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $jsonBytes
    }
    catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'unknown' }
        $detail = ''
        if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream()) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $detail = $reader.ReadToEnd()
            $detail = $detail -replace '(?i)("(?:password|pass|apikey|token|secret)"\s*:\s*")[^"]+', '$1<redacted>'
        }
        throw "API $Method $Uri failed with status $statusCode. $detail"
    }
}

function New-Field {
    param([string]$Name, [object]$Value)
    return @{ name = $Name; value = $Value }
}

function Set-FieldValue {
    param(
        [object[]]$Fields,
        [string]$Name,
        [object]$Value
    )

    $field = @($Fields | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
    if ($field.Count -eq 0) {
        throw "The qBittorrent schema does not contain the '$Name' field."
    }

    Set-ObjectProperty -Object $field[0] -Name 'value' -Value $Value
}

function Set-ObjectProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        try {
            $property.Value = $Value
        }
        catch {
            $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
        }
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Get-DownloadClientSchema {
    param(
        [string]$BaseUrl,
        [string]$ApiKey
    )

    $schemas = @(Invoke-ArrApi -Method GET -Uri "$BaseUrl/api/v3/downloadclient/schema" -ApiKey $ApiKey | ForEach-Object {
        if ($_ -is [System.Array]) { $_ } else { $_ }
    })
    foreach ($schema in $schemas) {
        if ($schema.implementation -eq 'QBittorrent') {
            return ,$schema
        }
    }

    throw 'Could not find qBittorrent in the download-client schema.'
}

function Get-QbitSession {
    param(
        [string]$Username,
        [string]$Password
    )

    try {
        $encodedUsername = [uri]::EscapeDataString($Username)
        $encodedPassword = [uri]::EscapeDataString($Password)
        $response = Invoke-WebRequest -Method POST -Uri 'http://localhost:8080/api/v2/auth/login' `
            -Body "username=$encodedUsername&password=$encodedPassword" `
            -ContentType 'application/x-www-form-urlencoded' `
            -SessionVariable qbitSession `
            -UseBasicParsing -TimeoutSec 10
    }
    catch {
        return $null
    }

    $responseContent = if ($response.Content -is [byte[]]) {
        [System.Text.Encoding]::UTF8.GetString($response.Content)
    }
    else {
        [string]$response.Content
    }

    if ($responseContent.Trim() -and $responseContent.Trim() -ne 'Ok.') {
        return $null
    }

    return $qbitSession
}

function Wait-QbitWebUi {
    $lastError = ''
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            Invoke-WebRequest -Uri 'http://localhost:8080' -UseBasicParsing -TimeoutSec 5 | Out-Null
            return
        }
        catch {
            $lastError = $_.Exception.Message
            if ($_.Exception.Response) {
                return
            }
            Start-Sleep -Seconds 1
        }
    }

    throw "qBittorrent Web UI did not become ready within 60 seconds after restart. Last error: $lastError"
}

function Get-QbitPasswordHash {
    param([string]$Password)

    $salt = New-Object byte[] 16
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($salt)
    }
    finally {
        $random.Dispose()
    }

    $passwordBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $deriveBytes = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($passwordBytes, $salt, 100000, [System.Security.Cryptography.HashAlgorithmName]::SHA512)
    try {
        $hash = $deriveBytes.GetBytes(64)
    }
    finally {
        $deriveBytes.Dispose()
    }

    return "@ByteArray($([Convert]::ToBase64String($salt)):$([Convert]::ToBase64String($hash)))"
}

function Set-QbitConfigValue {
    param(
        [string]$Content,
        [string]$Key,
        [string]$Value,
        [string]$Section = 'Preferences'
    )

    $pattern = "(?m)^$([regex]::Escape($Key))=.*$"
    if ([regex]::IsMatch($Content, $pattern)) {
        return [regex]::Replace($Content, $pattern, "$Key=$Value")
    }

    $sectionPattern = "(?m)^\[$([regex]::Escape($Section))\]\r?$"
    if (-not [regex]::IsMatch($Content, $sectionPattern)) {
        throw "qBittorrent config is missing its [$Section] section."
    }

    return [regex]::Replace($Content, $sectionPattern, "[$Section]`r`n$Key=$Value", 1)
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

function Set-QbitDownloadSettings {
    param([string]$ConfigPath)

    $configContent = Get-Content -Raw $ConfigPath
    $updatedContent = $configContent
    $updatedContent = Set-QbitConfigValue -Content $updatedContent -Section 'BitTorrent' -Key 'Session\DefaultSavePath' -Value '/data/torrents'
    $updatedContent = Set-QbitConfigValue -Content $updatedContent -Section 'BitTorrent' -Key 'Session\TempPath' -Value '/data/torrents/incomplete/'
    $updatedContent = Set-QbitConfigValue -Content $updatedContent -Section 'BitTorrent' -Key 'Session\GlobalMaxRatio' -Value '1'
    $updatedContent = Set-QbitConfigValue -Content $updatedContent -Section 'BitTorrent' -Key 'Session\GlobalMaxSeedingMinutes' -Value '1440'
    $updatedContent = Set-QbitConfigValue -Content $updatedContent -Section 'BitTorrent' -Key 'Session\GlobalMaxInactiveSeedingMinutes' -Value '1440'
    $updatedContent = Set-QbitConfigValue -Content $updatedContent -Section 'BitTorrent' -Key 'Session\ShareLimitAction' -Value 'Stop'
    $updatedContent = Set-QbitConfigValue -Content $updatedContent -Section 'Preferences' -Key 'Downloads\SavePath' -Value '/data/torrents'
    $updatedContent = Set-QbitConfigValue -Content $updatedContent -Section 'Preferences' -Key 'Downloads\TempPath' -Value '/data/torrents/incomplete/'

    if ($updatedContent -eq $configContent) {
        return $false
    }

    Invoke-DockerComposeQuiet -Arguments @('stop', 'qbittorrent')
    [System.IO.File]::WriteAllText((Resolve-Path $ConfigPath), $updatedContent, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-DockerComposeQuiet -Arguments @('up', '-d', 'qbittorrent')
    Wait-QbitWebUi
    return $true
}

function Ensure-QbitCredentials {
    param(
        [string]$Username,
        [string]$Password
    )

    if ($Password.Length -lt 6) {
        throw 'QBIT_PASS must be at least 6 characters long.'
    }
    if ($Username.Length -lt 3 -or $Username.Contains(':')) {
        throw 'QBIT_USER must be at least 3 characters long and cannot contain a colon.'
    }

    $configPath = '.\config\qbittorrent\qBittorrent\qBittorrent.conf'
    if (-not (Test-Path $configPath)) {
        throw "Missing qBittorrent config file: $configPath. Start qBittorrent once before bootstrap."
    }

    if (Set-QbitDownloadSettings -ConfigPath $configPath) {
        Write-Host 'qBittorrent download paths and seeding limits configured.'
    }

    $session = Get-QbitSession -Username $Username -Password $Password
    if ($session) {
        Write-Host 'qBittorrent Web UI credentials verified.'
        return
    }

    Write-Host 'Initializing qBittorrent Web UI credentials from QBIT_USER/QBIT_PASS...'
    Invoke-DockerComposeQuiet -Arguments @('stop', 'qbittorrent')

    try {
        $configContent = Get-Content -Raw $configPath
        $configContent = Set-QbitConfigValue -Content $configContent -Key 'WebUI\Username' -Value $Username
        $passwordHash = Get-QbitPasswordHash -Password $Password
        $configContent = Set-QbitConfigValue -Content $configContent -Key 'WebUI\Password_PBKDF2' -Value ('"' + $passwordHash + '"')
        [System.IO.File]::WriteAllText((Resolve-Path $configPath), $configContent, (New-Object System.Text.UTF8Encoding($false)))
    }
    finally {
        Invoke-DockerComposeQuiet -Arguments @('up', '-d', 'qbittorrent')
    }

    Wait-QbitWebUi
    if (-not (Get-QbitSession -Username $Username -Password $Password)) {
        throw 'qBittorrent did not accept QBIT_USER/QBIT_PASS after automatic configuration.'
    }
    Write-Host 'qBittorrent Web UI credentials initialized.'
}

function Find-ResourceByName {
    param(
        [object[]]$Resources,
        [string]$Name
    )

    foreach ($resource in @($Resources | ForEach-Object {
        if ($_ -is [System.Array]) { $_ } else { $_ }
    })) {
        $resourceName = [string]$resource.PSObject.Properties['name'].Value
        if ($resourceName -eq $Name) {
            return ,$resource
        }
    }

    return $null
}

function Upsert-ProwlarrApplication {
    param(
        [string]$Name,
        [string]$Implementation,
        [string]$ConfigContract,
        [string]$BaseUrl,
        [string]$ApiKey,
        [int[]]$SyncCategories,
        [int[]]$AnimeSyncCategories = @()
    )

    $appsUri = "$ProwlarrExternalUrl/api/v1/applications"
    $existing = Find-ResourceByName -Resources @(Invoke-ArrApi -Method GET -Uri $appsUri -ApiKey $script:ProwlarrApiKey) -Name $Name

    $fields = @(
        New-Field 'prowlarrUrl' $ProwlarrInternalUrl
        New-Field 'baseUrl' $BaseUrl
        New-Field 'apiKey' $ApiKey
        New-Field 'syncCategories' $SyncCategories
        New-Field 'syncRejectBlocklistedTorrentHashesWhileGrabbing' $true
    )

    if ($Implementation -eq 'Sonarr') {
        $fields += New-Field 'animeSyncCategories' $AnimeSyncCategories
        $fields += New-Field 'syncAnimeStandardFormatSearch' $false
    }

    $payload = @{
        enable = $true
        name = $Name
        implementationName = $Implementation
        implementation = $Implementation
        configContract = $ConfigContract
        syncLevel = 'fullSync'
        tags = @()
        fields = $fields
    }

    if ($existing) {
        $payload.id = $existing.id
        Invoke-ArrApi -Method PUT -Uri "$appsUri/$($existing.id)" -ApiKey $script:ProwlarrApiKey -Body $payload | Out-Null
        Write-Host "Updated Prowlarr app: $Name"
    }
    else {
        Invoke-ArrApi -Method POST -Uri $appsUri -ApiKey $script:ProwlarrApiKey -Body $payload | Out-Null
        Write-Host "Created Prowlarr app: $Name"
    }
}

function Upsert-QbitDownloadClient {
    param(
        [string]$AppName,
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$CategoryField,
        [string]$Category
    )

    $clientsUri = "$BaseUrl/api/v3/downloadclient"
    $existing = Find-ResourceByName -Resources @(Invoke-ArrApi -Method GET -Uri $clientsUri -ApiKey $ApiKey) -Name 'qBittorrent'

    $payload = Get-DownloadClientSchema -BaseUrl $BaseUrl -ApiKey $ApiKey
    Set-ObjectProperty -Object $payload -Name 'name' -Value 'qBittorrent'
    Set-ObjectProperty -Object $payload -Name 'enable' -Value $true
    Set-ObjectProperty -Object $payload -Name 'priority' -Value 1
    Set-ObjectProperty -Object $payload -Name 'removeCompletedDownloads' -Value $false
    Set-ObjectProperty -Object $payload -Name 'removeFailedDownloads' -Value $true
    Set-ObjectProperty -Object $payload -Name 'tags' -Value @()

    Set-FieldValue -Fields $payload.fields -Name 'host' -Value $QbitInternalHost
    Set-FieldValue -Fields $payload.fields -Name 'port' -Value $QbitInternalPort
    Set-FieldValue -Fields $payload.fields -Name 'useSsl' -Value $false
    Set-FieldValue -Fields $payload.fields -Name 'username' -Value $QbitUsername
    Set-FieldValue -Fields $payload.fields -Name 'password' -Value $QbitPassword
    Set-FieldValue -Fields $payload.fields -Name $CategoryField -Value $Category

    foreach ($optionalField in @('urlBase', ($CategoryField -replace 'Category$', 'ImportedCategory'), 'initialState', 'sequentialOrder', 'firstAndLast', 'contentLayout')) {
        $field = @($payload.fields | Where-Object { $_.name -eq $optionalField } | Select-Object -First 1)
        if ($field.Count -gt 0) {
            $value = switch ($optionalField) {
                'urlBase' { '' }
                { $_ -like '*ImportedCategory' } { "${Category}-imported" }
                'initialState' { 0 }
                'sequentialOrder' { $false }
                'firstAndLast' { $false }
                'contentLayout' { 0 }
            }
            Set-ObjectProperty -Object $field[0] -Name 'value' -Value $value
        }
    }

    if ($existing) {
        Set-ObjectProperty -Object $payload -Name 'id' -Value $existing.id
        Invoke-ArrApi -Method PUT -Uri "$clientsUri/$($existing.id)" -ApiKey $ApiKey -Body $payload | Out-Null
        Write-Host "Updated $AppName download client: qBittorrent"
    }
    else {
        Invoke-ArrApi -Method POST -Uri $clientsUri -ApiKey $ApiKey -Body $payload | Out-Null
        Write-Host "Created $AppName download client: qBittorrent"
    }
}

function Ensure-RootFolder {
    param(
        [string]$AppName,
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$Path
    )

    $rootFolderUri = "$BaseUrl/api/v3/rootfolder"
    $existing = @((Invoke-ArrApi -Method GET -Uri $rootFolderUri -ApiKey $ApiKey) | Where-Object { $_.path -eq $Path }) | Select-Object -First 1
    if ($existing) {
        Write-Host "$AppName root folder exists: $Path"
        return
    }

    Invoke-ArrApi -Method POST -Uri $rootFolderUri -ApiKey $ApiKey -Body @{ path = $Path } | Out-Null
    Write-Host "Created $AppName root folder: $Path"
}

Test-BootstrapEnvironment

if (-not $QbitUsername) { $QbitUsername = 'admin' }
if (-not $QbitPassword) {
    throw 'Missing QBIT_PASS. Set qBittorrent Web UI password in this shell as $env:QBIT_PASS before bootstrap.'
}

Ensure-QbitCredentials -Username $QbitUsername -Password $QbitPassword
& "$PSScriptRoot\bootstrap-ui-auth.ps1"
if ($LASTEXITCODE -ne 0) {
    throw 'UI authentication bootstrap failed; integration bootstrap was not applied.'
}

$script:ProwlarrApiKey = Get-ApiKeyFromConfig '.\config\prowlarr\config.xml'
$sonarrApiKey = Get-ApiKeyFromConfig '.\config\sonarr\config.xml'
$radarrApiKey = Get-ApiKeyFromConfig '.\config\radarr\config.xml'

Write-Host 'Bootstrapping media stack app links...'

Upsert-ProwlarrApplication -Name 'Sonarr' -Implementation 'Sonarr' -ConfigContract 'SonarrSettings' -BaseUrl $SonarrInternalUrl -ApiKey $sonarrApiKey -SyncCategories $SonarrSyncCategories -AnimeSyncCategories $SonarrAnimeSyncCategories
Upsert-ProwlarrApplication -Name 'Radarr' -Implementation 'Radarr' -ConfigContract 'RadarrSettings' -BaseUrl $RadarrInternalUrl -ApiKey $radarrApiKey -SyncCategories $RadarrSyncCategories

Upsert-QbitDownloadClient -AppName 'Sonarr' -BaseUrl $SonarrExternalUrl -ApiKey $sonarrApiKey -CategoryField 'tvCategory' -Category $TvCategory
Upsert-QbitDownloadClient -AppName 'Radarr' -BaseUrl $RadarrExternalUrl -ApiKey $radarrApiKey -CategoryField 'movieCategory' -Category $MovieCategory

Ensure-RootFolder -AppName 'Sonarr' -BaseUrl $SonarrExternalUrl -ApiKey $sonarrApiKey -Path $TvRootFolder
Ensure-RootFolder -AppName 'Radarr' -BaseUrl $RadarrExternalUrl -ApiKey $radarrApiKey -Path $MovieRootFolder

Write-Host 'Bootstrap complete.'
