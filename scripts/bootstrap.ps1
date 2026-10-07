param(
    [string]$QbitUsername = $env:QBIT_USER,
    [string]$QbitPassword = $env:QBIT_PASS,
    [string]$SabnzbdUsername = $env:SABNZBD_USER,
    [string]$SabnzbdPassword = $env:SABNZBD_PASS,
    [string]$ProwlarrExternalUrl = 'http://localhost:9696',
    [string]$SonarrExternalUrl = 'http://localhost:8989',
    [string]$RadarrExternalUrl = 'http://localhost:7878',
    [string]$ProwlarrInternalUrl = 'http://prowlarr:9696',
    [string]$SonarrInternalUrl = 'http://sonarr:8989',
    [string]$RadarrInternalUrl = 'http://radarr:7878',
    [string]$QbitInternalHost = 'gluetun',
    [int]$QbitInternalPort = 8080,
    [string]$SabnzbdInternalHost = 'sabnzbd',
    [int]$SabnzbdInternalPort = 8080,
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
        'SABNZBD_USER', 'SABNZBD_PASS',
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

    foreach ($prefix in @('SAB_SERVER', 'SAB_BACKUP_SERVER')) {
        $hostValue = [Environment]::GetEnvironmentVariable("${prefix}_HOST", 'Process')
        $userValue = [Environment]::GetEnvironmentVariable("${prefix}_USER", 'Process')
        if (-not $userValue) { $userValue = [Environment]::GetEnvironmentVariable("${prefix}_USERNAME", 'Process') }
        $passValue = [Environment]::GetEnvironmentVariable("${prefix}_PASS", 'Process')
        if (-not $passValue) { $passValue = [Environment]::GetEnvironmentVariable("${prefix}_PASSWORD", 'Process') }

        if ($hostValue -and (-not $userValue -or -not $passValue)) {
            throw "${prefix}_HOST is set, so ${prefix}_USER and ${prefix}_PASS are required."
        }
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
        throw "The download-client schema does not contain the '$Name' field."
    }

    Set-ObjectProperty -Object $field[0] -Name 'value' -Value $Value
}

function Set-FieldValueIfPresent {
    param(
        [object[]]$Fields,
        [string]$Name,
        [object]$Value
    )

    $field = @($Fields | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
    if ($field.Count -gt 0) {
        Set-ObjectProperty -Object $field[0] -Name 'value' -Value $Value
    }
}

function Set-DownloadClientPriorityFields {
    param(
        [object[]]$Fields,
        [string]$CategoryField,
        [int]$Priority
    )

    if ($CategoryField -eq 'tvCategory') {
        Set-FieldValueIfPresent -Fields $Fields -Name 'recentTvPriority' -Value $Priority
        Set-FieldValueIfPresent -Fields $Fields -Name 'olderTvPriority' -Value $Priority
    }
    elseif ($CategoryField -eq 'movieCategory') {
        Set-FieldValueIfPresent -Fields $Fields -Name 'recentMoviePriority' -Value $Priority
        Set-FieldValueIfPresent -Fields $Fields -Name 'olderMoviePriority' -Value $Priority
    }
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
        [string]$ApiKey,
        [string]$Implementation
    )

    $schemas = @(Invoke-ArrApi -Method GET -Uri "$BaseUrl/api/v3/downloadclient/schema" -ApiKey $ApiKey | ForEach-Object {
        if ($_ -is [System.Array]) { $_ } else { $_ }
    })
    foreach ($schema in $schemas) {
        if ($schema.implementation -eq $Implementation) {
            return ,$schema
        }
    }

    throw "Could not find $Implementation in the download-client schema."
}

function Get-SabnzbdApiKey {
    $configPath = '.\config\sabnzbd\sabnzbd.ini'
    if (-not (Test-Path $configPath)) {
        throw "Missing SABnzbd config file: $configPath. Start SABnzbd once before bootstrap."
    }

    $line = Get-Content $configPath | Where-Object { $_ -match '^api_key\s*=' } | Select-Object -First 1
    if (-not $line) { throw "SABnzbd config does not contain api_key in $configPath." }
    $apiKey = ($line -replace '^api_key\s*=\s*', '').Trim()
    if (-not $apiKey) { throw 'SABnzbd api_key is empty. Start SABnzbd once and rerun bootstrap.' }
    return $apiKey
}

function Set-IniValue {
    param(
        [string]$Content,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )

    $escapedSection = [regex]::Escape($Section)
    $escapedKey = [regex]::Escape($Key)
    $sectionPattern = "(?m)^\[$escapedSection\]\r?$"
    if (-not [regex]::IsMatch($Content, $sectionPattern)) {
        if ($Content -and -not $Content.EndsWith("`n")) { $Content += "`r`n" }
        $Content += "[$Section]`r`n"
    }

    $sectionBlockPattern = "(?ms)(^\[$escapedSection\]\r?\n)(.*?)(?=^\[|\z)"
    $sectionRegex = [System.Text.RegularExpressions.Regex]::new($sectionBlockPattern)
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $header = $match.Groups[1].Value
        $body = $match.Groups[2].Value
        $keyPattern = "(?m)^$escapedKey\s*=.*$"
        if ([regex]::IsMatch($body, $keyPattern)) {
            $body = [regex]::Replace($body, $keyPattern, "$Key = $Value")
        }
        else {
            if ($body -and -not $body.EndsWith("`n")) { $body += "`r`n" }
            $body += "$Key = $Value`r`n"
        }
        return $header + $body
    }

    return $sectionRegex.Replace($Content, $evaluator, 1)
}

function Add-IniListValue {
    param(
        [string]$Content,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )

    $escapedSection = [regex]::Escape($Section)
    $escapedKey = [regex]::Escape($Key)
    $sectionMatch = [regex]::Match($Content, "(?ms)(^\[$escapedSection\]\r?\n)(.*?)(?=^\[|\z)")
    $values = @()
    if ($sectionMatch.Success) {
        $keyMatch = [regex]::Match($sectionMatch.Groups[2].Value, "(?m)^$escapedKey\s*=\s*(.*)$")
        if ($keyMatch.Success) {
            $values = @($keyMatch.Groups[1].Value.Split(',') | ForEach-Object {
                $_.Trim().Trim('"').Trim("'")
            } | Where-Object { $_ })
        }
    }
    if ($values -notcontains $Value) {
        $values += $Value
    }
    return Set-IniValue -Content $Content -Section $Section -Key $Key -Value ($values -join ', ')
}

function Set-SabnzbdCategory {
    param(
        [string]$Content,
        [string]$Name,
        [string]$Directory
    )

    if (-not [regex]::IsMatch($Content, '(?m)^\[categories\]\r?$')) {
        if ($Content -and -not $Content.EndsWith("`n")) { $Content += "`r`n" }
        $Content += "[categories]`r`n"
    }

    $escapedName = [regex]::Escape($Name)
    $categoryPattern = "(?ms)(^\[\[$escapedName\]\]\r?\n)(.*?)(?=^\[\[|^\[|\z)"
    $categoryBlock = "[[$Name]]`r`npriority = 0`r`npp = 3`r`nname = $Name`r`nscript = None`r`ndir = $Directory`r`nnewzbin = `r`n"

    if ([regex]::IsMatch($Content, $categoryPattern)) {
        $categoryRegex = [System.Text.RegularExpressions.Regex]::new($categoryPattern)
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $body = $match.Groups[2].Value
            foreach ($entry in @(
                @{ Key = 'priority'; Value = '0' },
                @{ Key = 'pp'; Value = '3' },
                @{ Key = 'name'; Value = $Name },
                @{ Key = 'script'; Value = 'None' },
                @{ Key = 'dir'; Value = $Directory },
                @{ Key = 'newzbin'; Value = '' }
            )) {
                $keyPattern = "(?m)^$([regex]::Escape($entry.Key))\s*=.*$"
                if ([regex]::IsMatch($body, $keyPattern)) {
                    $body = [regex]::Replace($body, $keyPattern, "$($entry.Key) = $($entry.Value)")
                }
                else {
                    if ($body -and -not $body.EndsWith("`n")) { $body += "`r`n" }
                    $body += "$($entry.Key) = $($entry.Value)`r`n"
                }
            }
            return $match.Groups[1].Value + $body
        }

        return $categoryRegex.Replace($Content, $evaluator, 1)
    }

    $categoriesPattern = '(?ms)(^\[categories\]\r?\n)(.*?)(?=^\[|\z)'
    $categoriesRegex = [System.Text.RegularExpressions.Regex]::new($categoriesPattern)
    $appendEvaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $body = $match.Groups[2].Value
        if ($body -and -not $body.EndsWith("`n")) { $body += "`r`n" }
        return $match.Groups[1].Value + $body + $categoryBlock
    }

    return $categoriesRegex.Replace($Content, $appendEvaluator, 1)
}

function Get-EnvironmentValue {
    param(
        [string]$Name,
        [string]$Default = ''
    )

    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($null -eq $value -or $value -eq '') { return $Default }
    return $value
}

function Get-EnvironmentBool {
    param(
        [string]$Name,
        [bool]$Default
    )

    $value = Get-EnvironmentValue -Name $Name
    if (-not $value) { return $Default }
    return $value -match '^(1|true|yes|on)$'
}

function ConvertTo-SabnzbdIniValue {
    param([object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $(if ($Value) { '1' } else { '0' }) }

    $text = [string]$Value
    if ($text -match "[`r`n]") { throw 'SABnzbd server values cannot contain newlines.' }
    if ($text -match '^[0-9]+$') { return $text }
    if ($text -match '[#;=\[\]"''\s]') {
        return '"' + $text.Replace('\', '\\').Replace('"', '\"') + '"'
    }

    return $text
}

function New-SabnzbdServerSpec {
    param(
        [string]$Prefix,
        [int]$DefaultPriority,
        [bool]$DefaultOptional
    )

    $hostValue = Get-EnvironmentValue -Name "${Prefix}_HOST"
    if (-not $hostValue) { return $null }

    $usernameValue = Get-EnvironmentValue -Name "${Prefix}_USER"
    if (-not $usernameValue) { $usernameValue = Get-EnvironmentValue -Name "${Prefix}_USERNAME" }
    $passwordValue = Get-EnvironmentValue -Name "${Prefix}_PASS"
    if (-not $passwordValue) { $passwordValue = Get-EnvironmentValue -Name "${Prefix}_PASSWORD" }
    if (-not $usernameValue -or -not $passwordValue) {
        throw "${Prefix}_HOST is set, so ${Prefix}_USER and ${Prefix}_PASS are required."
    }

    $nameValue = Get-EnvironmentValue -Name "${Prefix}_NAME" -Default $hostValue
    $displayNameValue = Get-EnvironmentValue -Name "${Prefix}_DISPLAY_NAME" -Default $nameValue
    $portValue = [int](Get-EnvironmentValue -Name "${Prefix}_PORT" -Default '563')
    $connectionsValue = [int](Get-EnvironmentValue -Name "${Prefix}_CONNECTIONS" -Default '20')
    $priorityValue = [int](Get-EnvironmentValue -Name "${Prefix}_PRIORITY" -Default ([string]$DefaultPriority))
    $sslValue = Get-EnvironmentBool -Name "${Prefix}_SSL" -Default $true
    $enableValue = Get-EnvironmentBool -Name "${Prefix}_ENABLE" -Default $true
    $optionalValue = Get-EnvironmentBool -Name "${Prefix}_OPTIONAL" -Default $DefaultOptional
    $requiredValue = Get-EnvironmentBool -Name "${Prefix}_REQUIRED" -Default $false

    return [pscustomobject]@{
        Name = $nameValue
        DisplayName = $displayNameValue
        Host = $hostValue
        Port = $portValue
        Username = $usernameValue
        Password = $passwordValue
        Connections = $connectionsValue
        Ssl = $sslValue
        Enable = $enableValue
        Priority = $priorityValue
        Optional = $optionalValue
        Required = $requiredValue
        Retention = [int](Get-EnvironmentValue -Name "${Prefix}_RETENTION" -Default '0')
        SslVerify = [int](Get-EnvironmentValue -Name "${Prefix}_SSL_VERIFY" -Default '2')
    }
}

function Get-ObjectValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    $property = @($Object.PSObject.Properties[$Name] | Select-Object -First 1)
    if ($property.Count -eq 0 -or $null -eq $property[0].Value -or $property[0].Value -eq '') { return $Default }
    return $property[0].Value
}

function Get-SabnzbdServerSpecs {
    $serversJson = Get-EnvironmentValue -Name 'SAB_SERVERS_JSON'
    if ($serversJson) {
        try {
            $parsed = $serversJson | ConvertFrom-Json
        }
        catch {
            throw "SAB_SERVERS_JSON is not valid JSON: $_"
        }

        $serversProperty = @($parsed.PSObject.Properties['servers'] | Select-Object -First 1)
        $items = if ($serversProperty.Count -gt 0) { @($serversProperty[0].Value) } else { @($parsed) }
        return @($items | ForEach-Object {
            $entry = $_
            $hostValue = [string](Get-ObjectValue -Object $entry -Name 'host')
            $usernameValue = [string](Get-ObjectValue -Object $entry -Name 'username')
            $passwordValue = [string](Get-ObjectValue -Object $entry -Name 'password')
            if (-not $hostValue -or -not $usernameValue -or -not $passwordValue) {
                throw 'Each SAB_SERVERS_JSON entry requires host, username, and password.'
            }

            $nameValue = Get-ObjectValue -Object $entry -Name 'name' -Default $hostValue
            [pscustomobject]@{
                Name = $nameValue
                DisplayName = Get-ObjectValue -Object $entry -Name 'displayName' -Default $nameValue
                Host = $hostValue
                Port = [int](Get-ObjectValue -Object $entry -Name 'port' -Default 563)
                Username = $usernameValue
                Password = $passwordValue
                Connections = [int](Get-ObjectValue -Object $entry -Name 'connections' -Default 20)
                Ssl = [bool](Get-ObjectValue -Object $entry -Name 'ssl' -Default $true)
                Enable = [bool](Get-ObjectValue -Object $entry -Name 'enable' -Default $true)
                Priority = [int](Get-ObjectValue -Object $entry -Name 'priority' -Default 0)
                Optional = [bool](Get-ObjectValue -Object $entry -Name 'optional' -Default $false)
                Required = [bool](Get-ObjectValue -Object $entry -Name 'required' -Default $false)
                Retention = [int](Get-ObjectValue -Object $entry -Name 'retention' -Default 0)
                SslVerify = [int](Get-ObjectValue -Object $entry -Name 'sslVerify' -Default 2)
            }
        })
    }

    $serverSpecs = @()
    $primaryServer = New-SabnzbdServerSpec -Prefix 'SAB_SERVER' -DefaultPriority 0 -DefaultOptional $false
    if ($primaryServer) { $serverSpecs += $primaryServer }

    $backupServer = New-SabnzbdServerSpec -Prefix 'SAB_BACKUP_SERVER' -DefaultPriority 1 -DefaultOptional $true
    if ($backupServer) { $serverSpecs += $backupServer }

    return $serverSpecs
}

function Set-SabnzbdServer {
    param(
        [string]$Content,
        [object]$Server
    )

    if ($Server.Name -match "[`r`n\[\]]") {
        throw "Invalid SABnzbd server name: $($Server.Name)"
    }

    if (-not [regex]::IsMatch($Content, '(?m)^\[servers\]\r?$')) {
        if ($Content -and -not $Content.EndsWith("`n")) { $Content += "`r`n" }
        $Content += "[servers]`r`n"
    }

    $entries = [ordered]@{
        name = $Server.Name
        displayname = $Server.DisplayName
        host = $Server.Host
        port = $Server.Port
        timeout = 120
        username = $Server.Username
        password = $Server.Password
        connections = $Server.Connections
        ssl = $Server.Ssl
        ssl_verify = $Server.SslVerify
        enable = $Server.Enable
        required = $Server.Required
        optional = $Server.Optional
        retention = $Server.Retention
        send_group = 0
        priority = $Server.Priority
    }

    $escapedName = [regex]::Escape($Server.Name)
    $serverPattern = "(?ms)(^\[\[$escapedName\]\]\r?\n)(.*?)(?=^\[\[|^\[|\z)"
    if ([regex]::IsMatch($Content, $serverPattern)) {
        $serverRegex = [System.Text.RegularExpressions.Regex]::new($serverPattern)
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $body = $match.Groups[2].Value
            foreach ($key in $entries.Keys) {
                $value = ConvertTo-SabnzbdIniValue $entries[$key]
                $keyPattern = "(?m)^$([regex]::Escape($key))\s*=.*$"
                if ([regex]::IsMatch($body, $keyPattern)) {
                    $body = [regex]::Replace($body, $keyPattern, "$key = $value")
                }
                else {
                    if ($body -and -not $body.EndsWith("`n")) { $body += "`r`n" }
                    $body += "$key = $value`r`n"
                }
            }
            return $match.Groups[1].Value + $body
        }

        return $serverRegex.Replace($Content, $evaluator, 1)
    }

    $serverBlock = "[[$($Server.Name)]]`r`n"
    foreach ($key in $entries.Keys) {
        $serverBlock += "$key = $(ConvertTo-SabnzbdIniValue $entries[$key])`r`n"
    }

    $serversPattern = '(?ms)(^\[servers\]\r?\n)(.*?)(?=^\[|\z)'
    $serversRegex = [System.Text.RegularExpressions.Regex]::new($serversPattern)
    $appendEvaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $body = $match.Groups[2].Value
        if ($body -and -not $body.EndsWith("`n")) { $body += "`r`n" }
        return $match.Groups[1].Value + $body + $serverBlock
    }

    return $serversRegex.Replace($Content, $appendEvaluator, 1)
}

function Ensure-SonarrNamingConfig {
    param(
        [string]$BaseUrl,
        [string]$ApiKey
    )

    $uri = "$BaseUrl/api/v3/config/naming"
    $config = Invoke-ArrApi -Method GET -Uri $uri -ApiKey $ApiKey

    Set-ObjectProperty -Object $config -Name 'renameEpisodes' -Value $true
    Set-ObjectProperty -Object $config -Name 'replaceIllegalCharacters' -Value $true
    Set-ObjectProperty -Object $config -Name 'colonReplacementFormat' -Value 4
    Set-ObjectProperty -Object $config -Name 'customColonReplacementFormat' -Value ''
    Set-ObjectProperty -Object $config -Name 'multiEpisodeStyle' -Value 5
    Set-ObjectProperty -Object $config -Name 'standardEpisodeFormat' -Value '{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}'
    Set-ObjectProperty -Object $config -Name 'dailyEpisodeFormat' -Value '{Series Title} - {Air-Date} - {Episode Title} {Quality Full}'
    Set-ObjectProperty -Object $config -Name 'animeEpisodeFormat' -Value '{Series CleanTitleWithoutYear} {(Series Year)} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{MediaInfo AudioLanguages}{[MediaInfo VideoDynamicRangeType]}[{Mediainfo VideoCodec }{MediaInfo VideoBitDepth}bit]{-Release Group}'
    Set-ObjectProperty -Object $config -Name 'seriesFolderFormat' -Value '{Series CleanTitleWithoutYear} {(Series Year)}'
    Set-ObjectProperty -Object $config -Name 'seasonFolderFormat' -Value 'Season {season:00}'
    Set-ObjectProperty -Object $config -Name 'specialsFolderFormat' -Value 'Specials'

    Invoke-ArrApi -Method PUT -Uri $uri -ApiKey $ApiKey -Body $config | Out-Null
    Write-Host 'Sonarr episode naming baseline configured.'
}

function Ensure-SonarrMediaManagementConfig {
    param(
        [string]$BaseUrl,
        [string]$ApiKey
    )

    $uri = "$BaseUrl/api/v3/config/mediamanagement"
    $config = Invoke-ArrApi -Method GET -Uri $uri -ApiKey $ApiKey

    Set-ObjectProperty -Object $config -Name 'autoUnmonitorPreviouslyDownloadedEpisodes' -Value $false
    Set-ObjectProperty -Object $config -Name 'recycleBin' -Value ''
    Set-ObjectProperty -Object $config -Name 'recycleBinCleanupDays' -Value 7
    Set-ObjectProperty -Object $config -Name 'downloadPropersAndRepacks' -Value 'preferAndUpgrade'
    Set-ObjectProperty -Object $config -Name 'createEmptySeriesFolders' -Value $false
    Set-ObjectProperty -Object $config -Name 'deleteEmptyFolders' -Value $false
    Set-ObjectProperty -Object $config -Name 'fileDate' -Value 'none'
    Set-ObjectProperty -Object $config -Name 'rescanAfterRefresh' -Value 'always'
    Set-ObjectProperty -Object $config -Name 'setPermissionsLinux' -Value $false
    Set-ObjectProperty -Object $config -Name 'chmodFolder' -Value '755'
    Set-ObjectProperty -Object $config -Name 'chownGroup' -Value ''
    Set-ObjectProperty -Object $config -Name 'episodeTitleRequired' -Value 'always'
    Set-ObjectProperty -Object $config -Name 'skipFreeSpaceCheckWhenImporting' -Value $false
    Set-ObjectProperty -Object $config -Name 'minimumFreeSpaceWhenImporting' -Value 100
    Set-ObjectProperty -Object $config -Name 'copyUsingHardlinks' -Value $true
    Set-ObjectProperty -Object $config -Name 'useScriptImport' -Value $false
    Set-ObjectProperty -Object $config -Name 'scriptImportPath' -Value ''
    Set-ObjectProperty -Object $config -Name 'importExtraFiles' -Value $false
    Set-ObjectProperty -Object $config -Name 'extraFileExtensions' -Value 'srt'
    Set-ObjectProperty -Object $config -Name 'enableMediaInfo' -Value $true

    Invoke-ArrApi -Method PUT -Uri $uri -ApiKey $ApiKey -Body $config | Out-Null
    Write-Host 'Sonarr media management baseline configured.'
}

function Ensure-SabnzbdConfig {
    param(
        [string]$Username,
        [string]$Password
    )

    if ($Password.Length -lt 6) {
        throw 'SABNZBD_PASS must be at least 6 characters long.'
    }

    $configPath = '.\config\sabnzbd\sabnzbd.ini'
    if (-not (Test-Path $configPath)) {
        throw "Missing SABnzbd config file: $configPath. Start SABnzbd once before bootstrap."
    }

    $configContent = Get-Content -Raw $configPath
    $updatedContent = $configContent
    $updatedContent = Set-IniValue -Content $updatedContent -Section 'misc' -Key 'host' -Value '0.0.0.0'
    $updatedContent = Set-IniValue -Content $updatedContent -Section 'misc' -Key 'port' -Value '8080'
    $updatedContent = Set-IniValue -Content $updatedContent -Section 'misc' -Key 'username' -Value $Username
    $updatedContent = Set-IniValue -Content $updatedContent -Section 'misc' -Key 'password' -Value $Password
    $updatedContent = Set-IniValue -Content $updatedContent -Section 'misc' -Key 'download_dir' -Value '/data/usenet/incomplete'
    $updatedContent = Set-IniValue -Content $updatedContent -Section 'misc' -Key 'complete_dir' -Value '/data/usenet/complete'
    $updatedContent = Add-IniListValue -Content $updatedContent -Section 'misc' -Key 'host_whitelist' -Value 'sabnzbd'
    $updatedContent = Set-SabnzbdCategory -Content $updatedContent -Name 'tv' -Directory 'tv'
    $updatedContent = Set-SabnzbdCategory -Content $updatedContent -Name 'movies' -Directory 'movies'

    $serverSpecs = @(Get-SabnzbdServerSpecs)
    foreach ($serverSpec in $serverSpecs) {
        $updatedContent = Set-SabnzbdServer -Content $updatedContent -Server $serverSpec
    }

    if ($updatedContent -eq $configContent) {
        if ($serverSpecs.Count -gt 0) {
            Write-Host "SABnzbd UI credentials, download paths, and $($serverSpecs.Count) server(s) verified."
        }
        else {
            Write-Host 'SABnzbd UI credentials and download paths verified. Set SAB_SERVER_HOST/SAB_SERVER_USER/SAB_SERVER_PASS to automate provider servers.'
        }
        return
    }

    Invoke-DockerComposeQuiet -Arguments @('stop', 'sabnzbd')
    [System.IO.File]::WriteAllText((Resolve-Path $configPath), $updatedContent, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-DockerComposeQuiet -Arguments @('up', '-d', 'sabnzbd')
    if ($serverSpecs.Count -gt 0) {
        Write-Host "SABnzbd UI credentials, download paths, and $($serverSpecs.Count) server(s) configured."
    }
    else {
        Write-Host 'SABnzbd UI credentials and download paths configured.'
    }
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

function Wait-SabnzbdWebUi {
    $lastError = ''
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            Invoke-WebRequest -Uri 'http://localhost:8081' -UseBasicParsing -TimeoutSec 5 | Out-Null
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

    throw "SABnzbd Web UI did not become ready within 60 seconds after restart. Last error: $lastError"
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
    Wait-SabnzbdWebUi
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

    $payload = Get-DownloadClientSchema -BaseUrl $BaseUrl -ApiKey $ApiKey -Implementation 'QBittorrent'
    Set-ObjectProperty -Object $payload -Name 'name' -Value 'qBittorrent'
    Set-ObjectProperty -Object $payload -Name 'enable' -Value $true
    Set-ObjectProperty -Object $payload -Name 'priority' -Value 2
    Set-ObjectProperty -Object $payload -Name 'removeCompletedDownloads' -Value $false
    Set-ObjectProperty -Object $payload -Name 'removeFailedDownloads' -Value $true
    Set-ObjectProperty -Object $payload -Name 'tags' -Value @()

    Set-FieldValue -Fields $payload.fields -Name 'host' -Value $QbitInternalHost
    Set-FieldValue -Fields $payload.fields -Name 'port' -Value $QbitInternalPort
    Set-FieldValue -Fields $payload.fields -Name 'useSsl' -Value $false
    Set-FieldValue -Fields $payload.fields -Name 'username' -Value $QbitUsername
    Set-FieldValue -Fields $payload.fields -Name 'password' -Value $QbitPassword
    Set-FieldValue -Fields $payload.fields -Name $CategoryField -Value $Category
    Set-DownloadClientPriorityFields -Fields $payload.fields -CategoryField $CategoryField -Priority 0

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

function Upsert-SabnzbdDownloadClient {
    param(
        [string]$AppName,
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$SabnzbdApiKey,
        [string]$CategoryField,
        [string]$Category
    )

    $clientsUri = "$BaseUrl/api/v3/downloadclient"
    $existing = Find-ResourceByName -Resources @(Invoke-ArrApi -Method GET -Uri $clientsUri -ApiKey $ApiKey) -Name 'SABnzbd'

    $payload = Get-DownloadClientSchema -BaseUrl $BaseUrl -ApiKey $ApiKey -Implementation 'Sabnzbd'
    Set-ObjectProperty -Object $payload -Name 'name' -Value 'SABnzbd'
    Set-ObjectProperty -Object $payload -Name 'enable' -Value $true
    Set-ObjectProperty -Object $payload -Name 'priority' -Value 1
    Set-ObjectProperty -Object $payload -Name 'removeCompletedDownloads' -Value $true
    Set-ObjectProperty -Object $payload -Name 'removeFailedDownloads' -Value $true
    Set-ObjectProperty -Object $payload -Name 'tags' -Value @()

    Set-FieldValue -Fields $payload.fields -Name 'host' -Value $SabnzbdInternalHost
    Set-FieldValue -Fields $payload.fields -Name 'port' -Value $SabnzbdInternalPort
    Set-FieldValue -Fields $payload.fields -Name 'useSsl' -Value $false
    Set-FieldValue -Fields $payload.fields -Name 'urlBase' -Value ''
    Set-FieldValue -Fields $payload.fields -Name 'apiKey' -Value $SabnzbdApiKey
    Set-FieldValue -Fields $payload.fields -Name 'username' -Value $SabnzbdUsername
    Set-FieldValue -Fields $payload.fields -Name 'password' -Value $SabnzbdPassword
    Set-FieldValue -Fields $payload.fields -Name $CategoryField -Value $Category
    Set-DownloadClientPriorityFields -Fields $payload.fields -CategoryField $CategoryField -Priority -100

    if ($existing) {
        Set-ObjectProperty -Object $payload -Name 'id' -Value $existing.id
        Invoke-ArrApi -Method PUT -Uri "$clientsUri/$($existing.id)" -ApiKey $ApiKey -Body $payload | Out-Null
        Write-Host "Updated $AppName download client: SABnzbd"
    }
    else {
        Invoke-ArrApi -Method POST -Uri $clientsUri -ApiKey $ApiKey -Body $payload | Out-Null
        Write-Host "Created $AppName download client: SABnzbd"
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
if (-not $SabnzbdUsername) { $SabnzbdUsername = 'admin' }
if (-not $SabnzbdPassword) {
    throw 'Missing SABNZBD_PASS. Set SABnzbd Web UI password in this shell as $env:SABNZBD_PASS before bootstrap.'
}

Ensure-QbitCredentials -Username $QbitUsername -Password $QbitPassword
Ensure-SabnzbdConfig -Username $SabnzbdUsername -Password $SabnzbdPassword
& "$PSScriptRoot\bootstrap-ui-auth.ps1"
if ($LASTEXITCODE -ne 0) {
    throw 'UI authentication bootstrap failed; integration bootstrap was not applied.'
}

$script:ProwlarrApiKey = Get-ApiKeyFromConfig '.\config\prowlarr\config.xml'
$sonarrApiKey = Get-ApiKeyFromConfig '.\config\sonarr\config.xml'
$radarrApiKey = Get-ApiKeyFromConfig '.\config\radarr\config.xml'
$sabnzbdApiKey = Get-SabnzbdApiKey

Write-Host 'Bootstrapping media stack app links...'

Upsert-ProwlarrApplication -Name 'Sonarr' -Implementation 'Sonarr' -ConfigContract 'SonarrSettings' -BaseUrl $SonarrInternalUrl -ApiKey $sonarrApiKey -SyncCategories $SonarrSyncCategories -AnimeSyncCategories $SonarrAnimeSyncCategories
Upsert-ProwlarrApplication -Name 'Radarr' -Implementation 'Radarr' -ConfigContract 'RadarrSettings' -BaseUrl $RadarrInternalUrl -ApiKey $radarrApiKey -SyncCategories $RadarrSyncCategories

if (Test-Path '.\indexers.json') {
    & "$PSScriptRoot\import-prowlarr-indexers.ps1"
    if ($LASTEXITCODE -ne 0) {
        throw 'Prowlarr indexer import failed.'
    }
}
else {
    Write-Host 'Skipping Prowlarr indexer import: indexers.json does not exist. Copy indexers.example.json to indexers.json to enable it.'
}

Ensure-SonarrNamingConfig -BaseUrl $SonarrExternalUrl -ApiKey $sonarrApiKey
Ensure-SonarrMediaManagementConfig -BaseUrl $SonarrExternalUrl -ApiKey $sonarrApiKey

Upsert-SabnzbdDownloadClient -AppName 'Sonarr' -BaseUrl $SonarrExternalUrl -ApiKey $sonarrApiKey -SabnzbdApiKey $sabnzbdApiKey -CategoryField 'tvCategory' -Category $TvCategory
Upsert-SabnzbdDownloadClient -AppName 'Radarr' -BaseUrl $RadarrExternalUrl -ApiKey $radarrApiKey -SabnzbdApiKey $sabnzbdApiKey -CategoryField 'movieCategory' -Category $MovieCategory
Upsert-QbitDownloadClient -AppName 'Sonarr' -BaseUrl $SonarrExternalUrl -ApiKey $sonarrApiKey -CategoryField 'tvCategory' -Category $TvCategory
Upsert-QbitDownloadClient -AppName 'Radarr' -BaseUrl $RadarrExternalUrl -ApiKey $radarrApiKey -CategoryField 'movieCategory' -Category $MovieCategory

Ensure-RootFolder -AppName 'Sonarr' -BaseUrl $SonarrExternalUrl -ApiKey $sonarrApiKey -Path $TvRootFolder
Ensure-RootFolder -AppName 'Radarr' -BaseUrl $RadarrExternalUrl -ApiKey $radarrApiKey -Path $MovieRootFolder

Write-Host ''
Write-Host 'Configuring Seerr...'
& "$PSScriptRoot\bootstrap-seerr.ps1" -SonarrExternalUrl $SonarrExternalUrl -RadarrExternalUrl $RadarrExternalUrl
if ($LASTEXITCODE -ne 0) {
    Write-Host 'WARNING: Seerr bootstrap failed, but main bootstrap completed. Restart Seerr and try again manually.'
}
else {
    docker compose restart seerr | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Seerr restart failed after updating its service configuration.'
    }

    $seerrReady = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        try {
            Invoke-WebRequest -Method GET -Uri 'http://localhost:5055/api/v1/status' -UseBasicParsing -TimeoutSec 2 | Out-Null
            $seerrReady = $true
            break
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }
    if (-not $seerrReady) {
        throw 'Seerr did not become ready within 120 seconds after restart.'
    }

    & "$PSScriptRoot\bootstrap-jellyfin.ps1" -MoonbaseReprovisionOnly
    if ($LASTEXITCODE -ne 0) {
        throw 'Moonbase Seerr webhook reprovision failed.'
    }
}

Write-Host 'Bootstrap complete.'
