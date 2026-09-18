param(
    [string]$SonarrUsername = $env:SONARR_USER,
    [string]$SonarrPassword = $env:SONARR_PASS,
    [string]$RadarrUsername = $env:RADARR_USER,
    [string]$RadarrPassword = $env:RADARR_PASS,
    [string]$ProwlarrUsername = $env:PROWLARR_USER,
    [string]$ProwlarrPassword = $env:PROWLARR_PASS,
    [string]$BazarrUsername = $env:BAZARR_USER,
    [string]$BazarrPassword = $env:BAZARR_PASS,
    [string]$JellyfinUsername = $env:JELLYFIN_USER,
    [string]$JellyfinPassword = $env:JELLYFIN_PASS,
    [string]$SeerrEmail = $env:SEERR_EMAIL
)

$ErrorActionPreference = 'Stop'

trap {
    Write-Host $_.Exception.Message
    exit 1
}

function Require-SecretValues {
    $values = @{
        SONARR_USER = $SonarrUsername
        SONARR_PASS = $SonarrPassword
        RADARR_USER = $RadarrUsername
        RADARR_PASS = $RadarrPassword
        PROWLARR_USER = $ProwlarrUsername
        PROWLARR_PASS = $ProwlarrPassword
        BAZARR_USER = $BazarrUsername
        BAZARR_PASS = $BazarrPassword
        JELLYFIN_USER = $JellyfinUsername
        JELLYFIN_PASS = $JellyfinPassword
        SEERR_EMAIL = $SeerrEmail
    }

    $missing = @($values.GetEnumerator() | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Value) } | ForEach-Object Key)
    if ($missing.Count -gt 0) {
        throw "Missing UI-auth secret environment variable(s): $($missing -join ', '). Set them in your shell or secret manager before bootstrap."
    }
}

function Get-ArrApiKey {
    param([string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        throw "Missing app config: $ConfigPath. Start the stack once before bootstrap."
    }

    $apiKey = [string]([xml](Get-Content $ConfigPath)).Config.ApiKey
    if (-not $apiKey) {
        throw "No API key found in $ConfigPath."
    }

    return $apiKey
}

function Invoke-JsonRequest {
    param(
        [ValidateSet('GET', 'POST', 'PUT')]
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers = @{},
        [object]$Body = $null,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession = $null,
        [switch]$CaptureSession
    )

    $parameters = @{ Method = $Method; Uri = $Uri; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 20 }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 30))
    }
    if ($WebSession) { $parameters.WebSession = $WebSession }
    if ($CaptureSession) { $parameters.SessionVariable = 'capturedSession' }

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
    $result = if ([string]::IsNullOrWhiteSpace($content)) { $null } else { $content | ConvertFrom-Json }
    if ($CaptureSession) { return @{ Result = $result; Session = $capturedSession } }
    return $result
}

function Test-ProwlarrFormsLogin {
    param(
        [string]$BaseUrl,
        [string]$Username,
        [string]$Password
    )

    $encodedUsername = [uri]::EscapeDataString($Username)
    $encodedPassword = [uri]::EscapeDataString($Password)
    $body = "username=$encodedUsername&password=$encodedPassword&rememberMe=on"
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    for ($attempt = 1; $attempt -le 90; $attempt++) {
        $response = $null
        try {
            $request = [System.Net.HttpWebRequest]::Create("$BaseUrl/login")
            $request.Method = 'POST'
            $request.ContentType = 'application/x-www-form-urlencoded'
            $request.AllowAutoRedirect = $false
            $request.Timeout = 5000
            $request.ContentLength = $bodyBytes.Length

            $requestStream = $request.GetRequestStream()
            try {
                $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
            }
            finally {
                $requestStream.Dispose()
            }

            $response = $request.GetResponse()
            if ([int]$response.StatusCode -eq 302 -and [string]$response.Headers['Location'] -eq '/') { return $true }
        }
        catch {
            if ($_.Exception.Response) {
                $response = $_.Exception.Response
                if ([int]$response.StatusCode -eq 302 -and [string]$response.Headers['Location'] -eq '/') { return $true }
            }
        }
        finally {
            if ($response) { $response.Dispose() }
        }

        Start-Sleep -Seconds 1
    }

    return $false
}

function Wait-ArrHostConfig {
    param(
        [string]$ServiceName,
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$ApiVersion
    )

    $lastError = ''
    for ($attempt = 1; $attempt -le 120; $attempt++) {
        try {
            $hostConfig = Invoke-JsonRequest -Method GET -Uri "$BaseUrl/api/$ApiVersion/config/host" -Headers @{ 'X-Api-Key' = $ApiKey }
            if ($hostConfig) { return $hostConfig }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds 1
    }

    throw "$ServiceName API did not become ready within 120 seconds. Last error: $lastError"
}

function Set-ArrFormsAuthentication {
    param(
        [string]$ServiceName,
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$Username,
        [string]$Password,
        [string]$ApiVersion = 'v3'
    )

    if ($Password.Length -lt 6) {
        throw "$ServiceName password must be at least 6 characters."
    }

    $hostConfig = Wait-ArrHostConfig -ServiceName $ServiceName -BaseUrl $BaseUrl -ApiKey $ApiKey -ApiVersion $ApiVersion

    $hostConfig.authenticationMethod = 'Forms'
    $hostConfig.authenticationRequired = 'Enabled'
    $hostConfig.username = $Username
    $hostConfig.password = $Password
    $hostConfig.passwordConfirmation = $Password

    Invoke-JsonRequest -Method PUT -Uri "$BaseUrl/api/$ApiVersion/config/host/$($hostConfig.id)" -Headers @{ 'X-Api-Key' = $ApiKey } -Body $hostConfig | Out-Null
    Write-Host "$ServiceName Forms login configured."

    if ($ServiceName -eq 'Prowlarr') {
        Invoke-DockerComposeQuiet -Arguments @('restart', 'prowlarr')
        Write-Host 'Prowlarr restarted to activate Forms authentication.'

        if (-not (Test-ProwlarrFormsLogin -BaseUrl $BaseUrl -Username $Username -Password $Password)) {
            throw 'Prowlarr rejected PROWLARR_USER/PROWLARR_PASS after Forms user creation and restart.'
        }
        Write-Host 'Prowlarr Forms login verified.'
    }
}

function Get-Md5Hex {
    param([string]$Value)

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        return ([System.BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $md5.Dispose()
    }
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

function Set-YamlAuthValue {
    param([string]$Content, [string]$Name, [string]$Value)

    $pattern = "(?ms)(^auth:\r?\n.*?^  $([regex]::Escape($Name)):)[^\r\n]*"
    if (-not [regex]::IsMatch($Content, $pattern)) {
        throw "Bazarr config is missing auth.$Name."
    }

    return [regex]::Replace($Content, $pattern, "`$1 $Value", 1)
}

function Set-BazarrFormsAuthentication {
    $configPath = '.\config\bazarr\config\config.yaml'
    if (-not (Test-Path $configPath)) {
        throw "Missing Bazarr config: $configPath. Start Bazarr once before bootstrap."
    }

    $content = Get-Content -Raw $configPath
    $content = Set-YamlAuthValue -Content $content -Name 'type' -Value 'form'
    $content = Set-YamlAuthValue -Content $content -Name 'username' -Value ("'$BazarrUsername'")
    $content = Set-YamlAuthValue -Content $content -Name 'password' -Value ("'$((Get-Md5Hex $BazarrPassword))'")
    [System.IO.File]::WriteAllText((Resolve-Path $configPath), $content, (New-Object System.Text.UTF8Encoding($false)))

    Invoke-DockerComposeQuiet -Arguments @('restart', 'bazarr')
    Write-Host 'Bazarr Forms login configured.'
}

function Get-JellyfinHeaders {
    return @{ Authorization = 'MediaBrowser Client="media-stack", Device="bootstrap", DeviceId="media-stack-bootstrap", Version="1.0"' }
}

function Get-JellyfinSession {
    try {
        return Invoke-JsonRequest -Method POST -Uri 'http://localhost:8096/Users/AuthenticateByName' -Headers (Get-JellyfinHeaders) -Body @{ Username = $JellyfinUsername; Pw = $JellyfinPassword } -CaptureSession
    }
    catch {
        return $null
    }
}

function Ensure-JellyfinAdmin {
    $session = Get-JellyfinSession
    if ($session) {
        Write-Host 'Jellyfin administrator credentials verified.'
        return $session
    }

    try {
        Invoke-JsonRequest -Method GET -Uri 'http://localhost:8096/Startup/User' -Headers (Get-JellyfinHeaders) | Out-Null
        Invoke-JsonRequest -Method POST -Uri 'http://localhost:8096/Startup/User' -Headers (Get-JellyfinHeaders) -Body @{ Name = $JellyfinUsername; Password = $JellyfinPassword } | Out-Null
        Invoke-JsonRequest -Method POST -Uri 'http://localhost:8096/Startup/Complete' -Headers (Get-JellyfinHeaders) -Body @{} | Out-Null
    }
    catch {
        throw 'Jellyfin credentials were rejected and its first-run wizard cannot be initialized. Use a fresh Jellyfin config or supply the existing Jellyfin admin credentials.'
    }

    $session = Get-JellyfinSession
    if (-not $session) { throw 'Jellyfin did not accept JELLYFIN_USER/JELLYFIN_PASS after first-run initialization.' }
    Write-Host 'Jellyfin administrator initialized.'
    return $session
}

function Wait-JellyfinAuthenticated {
    param([int]$TimeoutSeconds = 90)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = ''
    while ((Get-Date) -lt $deadline) {
        $session = Get-JellyfinSession
        if ($session) { return $session }
        $lastError = 'Jellyfin authentication endpoint is not ready yet.'
        Start-Sleep -Seconds 2
    }

    throw "Jellyfin did not accept the administrator credentials within $TimeoutSeconds seconds. $lastError"
}

function Initialize-SeerrWithJellyfin {
    param([object]$JellyfinSession)

    try {
        $publicSettings = Invoke-JsonRequest -Method GET -Uri 'http://localhost:5055/api/v1/settings/public'
        if ($publicSettings.initialized) {
            Write-Host 'Seerr administrator is already configured.'
            return
        }
    }
    catch {
    }

    $body = @{
        username = $JellyfinUsername
        password = $JellyfinPassword
        hostname = 'jellyfin'
        port = 8096
        useSsl = $false
        urlBase = ''
        email = $SeerrEmail
        serverType = 2
    }

    try {
        $login = Invoke-JsonRequest -Method POST -Uri 'http://localhost:5055/api/v1/auth/jellyfin' -Body $body -CaptureSession
        Invoke-JsonRequest -Method POST -Uri 'http://localhost:5055/api/v1/settings/initialize' -WebSession $login.Session -Body @{} | Out-Null
        Write-Host 'Seerr administrator initialized from Jellyfin credentials.'
    }
    catch {
        throw "Seerr setup failed. $($_.Exception.Message)"
    }
}

Require-SecretValues

$sonarrApiKey = Get-ArrApiKey '.\config\sonarr\config.xml'
$radarrApiKey = Get-ArrApiKey '.\config\radarr\config.xml'
$prowlarrApiKey = Get-ArrApiKey '.\config\prowlarr\config.xml'

Set-ArrFormsAuthentication -ServiceName 'Sonarr' -BaseUrl 'http://localhost:8989' -ApiKey $sonarrApiKey -Username $SonarrUsername -Password $SonarrPassword
Set-ArrFormsAuthentication -ServiceName 'Radarr' -BaseUrl 'http://localhost:7878' -ApiKey $radarrApiKey -Username $RadarrUsername -Password $RadarrPassword
Set-ArrFormsAuthentication -ServiceName 'Prowlarr' -BaseUrl 'http://localhost:9696' -ApiKey $prowlarrApiKey -Username $ProwlarrUsername -Password $ProwlarrPassword -ApiVersion 'v1'
Set-BazarrFormsAuthentication
$jellyfinSession = Ensure-JellyfinAdmin
& "$PSScriptRoot\bootstrap-jellyfin.ps1" -JellyfinUsername $JellyfinUsername -JellyfinPassword $JellyfinPassword
if ($LASTEXITCODE -ne 0) {
    throw 'Jellyfin baseline bootstrap failed.'
}
$jellyfinSession = Wait-JellyfinAuthenticated
Initialize-SeerrWithJellyfin -JellyfinSession $jellyfinSession

Write-Host 'UI authentication bootstrap complete.'
