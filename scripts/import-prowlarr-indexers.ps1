param(
    [string]$ConfigPath = '.\indexers.json',
    [string]$ProwlarrExternalUrl = 'http://localhost:9696',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

trap {
    Write-Host $_.Exception.Message
    exit 1
}

function Get-ApiKeyFromConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Missing config file: $Path. Start Prowlarr once before importing indexers."
    }

    $xml = [xml](Get-Content $Path)
    $apiKey = [string]$xml.Config.ApiKey
    if (-not $apiKey) {
        throw "No ApiKey found in $Path."
    }

    return $apiKey
}

function Invoke-ProwlarrApi {
    param(
        [ValidateSet('GET', 'POST', 'PUT')]
        [string]$Method,
        [string]$Uri,
        [string]$ApiKey,
        [object]$Body = $null
    )

    $headers = @{ 'X-Api-Key' = $ApiKey }
    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }

    $json = ConvertTo-Json -InputObject $Body -Depth 30
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $jsonBytes
    }
    catch {
        $response = $_.Exception.Response
        if ($response -and $response.GetResponseStream()) {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            $bodyText = $reader.ReadToEnd()
            if ($bodyText) {
                throw "Prowlarr API $Method $Uri failed: $(Redact-SensitiveText $bodyText)"
            }
        }

        throw "Prowlarr API $Method $Uri failed: $($_.Exception.Message)"
    }
}

function Redact-SensitiveText {
    param([string]$Text)

    if (-not $Text) { return $Text }

    return $Text `
        -replace '(?i)("(?:password|pass|apikey|apiKey|token|cookie|cookies|auth|secret)"\s*:\s*")[^"]+', '$1<redacted>' `
        -replace '(?i)((?:password|pass|apikey|apiKey|token|cookie|cookies|auth|secret)[^\r\n:=]*\s*[:=]\s*)[^\r\n,}]+', '$1<redacted>'
}

function Resolve-ConfigValue {
    param([object]$Value)

    if ($Value -is [string] -and $Value.StartsWith('env:')) {
        $name = $Value.Substring(4)
        $resolved = [Environment]::GetEnvironmentVariable($name)
        if (-not $resolved) {
            throw "Missing environment variable '$name' required by $ConfigPath."
        }
        return $resolved
    }

    return $Value
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

function Set-IndexerField {
    param(
        [object]$Indexer,
        [string]$FieldName,
        [object]$Value
    )

    $field = @($Indexer.fields) | Where-Object { $_.name -eq $FieldName } | Select-Object -First 1
    if (-not $field) {
        throw "Indexer '$($Indexer.name)' does not have a field named '$FieldName'."
    }

    Set-ObjectProperty -Object $field -Name 'value' -Value (Resolve-ConfigValue $Value)
}

function ConvertTo-FlatArray {
    param([object]$Value)

    foreach ($item in @($Value)) {
        if ($item -is [System.Array]) {
            foreach ($nestedItem in $item) {
                $nestedItem
            }
        }
        else {
            $item
        }
    }
}

function Find-IndexerSchema {
    param(
        [object[]]$Schemas,
        [string]$SchemaName
    )

    $flatSchemas = @($Schemas | ForEach-Object {
        if ($_ -is [System.Array]) { $_ } else { $_ }
    })

    foreach ($candidate in $flatSchemas) {
        $candidateName = [string]$candidate.PSObject.Properties['name'].Value
        $candidateDefinitionName = [string]$candidate.PSObject.Properties['definitionName'].Value
        if ($candidateName -eq $SchemaName) { return ,$candidate }
        if ($candidateDefinitionName -eq $SchemaName) { return ,$candidate }
    }

    return $null
}

if (-not (Test-Path $ConfigPath)) {
    throw "Missing indexer config: $ConfigPath. Copy indexers.example.json to indexers.json and edit it."
}

$prowlarrApiKey = Get-ApiKeyFromConfig '.\config\prowlarr\config.xml'
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.indexers) {
    throw "No indexers array found in $ConfigPath."
}

$indexerUri = "$ProwlarrExternalUrl/api/v1/indexer"
$schemas = @(ConvertTo-FlatArray (Invoke-ProwlarrApi -Method GET -Uri "$indexerUri/schema" -ApiKey $prowlarrApiKey))
$existingIndexers = @(ConvertTo-FlatArray (Invoke-ProwlarrApi -Method GET -Uri $indexerUri -ApiKey $prowlarrApiKey))

:indexer foreach ($item in @($config.indexers)) {
    if ($null -ne $item.enable -and -not [bool]$item.enable) {
        Write-Host "Skipping disabled indexer entry: $($item.schemaName)"
        continue
    }

    $schemaName = [string]$item.schemaName
    if (-not $schemaName) {
        throw 'Every indexer entry must include schemaName.'
    }

    $schema = Find-IndexerSchema -Schemas $schemas -SchemaName $schemaName
    if (-not $schema) {
        throw "No Prowlarr indexer schema found for '$schemaName'. Check the spelling against /api/v1/indexer/schema."
    }

    $payload = $schema
    Set-ObjectProperty -Object $payload -Name 'name' -Value $(if ($item.name) { [string]$item.name } else { [string]$schema.name })
    Set-ObjectProperty -Object $payload -Name 'enable' -Value $(if ($null -ne $item.enable) { [bool]$item.enable } else { $true })

    if ($null -ne $item.priority) { Set-ObjectProperty -Object $payload -Name 'priority' -Value ([int]$item.priority) }
    if ($null -ne $item.appProfileId) { Set-ObjectProperty -Object $payload -Name 'appProfileId' -Value ([int]$item.appProfileId) }
    if ($null -ne $item.downloadClientId) { Set-ObjectProperty -Object $payload -Name 'downloadClientId' -Value ([int]$item.downloadClientId) }
    if ($item.tags) { Set-ObjectProperty -Object $payload -Name 'tags' -Value @($item.tags) }

    if ($item.fields) {
        $fieldProperties = $item.fields.PSObject.Properties
        foreach ($property in $fieldProperties) {
            if ($property.Value -is [string] -and $property.Value.StartsWith('env:')) {
                $environmentVariable = $property.Value.Substring(4)
                if (-not [Environment]::GetEnvironmentVariable($environmentVariable, 'Process')) {
                    Write-Host "Skipping indexer entry '$schemaName': missing environment variable '$environmentVariable'."
                    continue indexer
                }
            }
            Set-IndexerField -Indexer $payload -FieldName $property.Name -Value $property.Value
        }
    }

    $existing = $existingIndexers | Where-Object { $_.name -eq $payload.name } | Select-Object -First 1
    if ($DryRun) {
        ConvertTo-Json -InputObject $payload -Depth 30
        continue
    }

    if ($existing) {
        Set-ObjectProperty -Object $payload -Name 'id' -Value $existing.id
        Invoke-ProwlarrApi -Method PUT -Uri "$indexerUri/$($existing.id)" -ApiKey $prowlarrApiKey -Body $payload | Out-Null
        Write-Host "Updated Prowlarr indexer: $($payload.name)"
    }
    else {
        Invoke-ProwlarrApi -Method POST -Uri $indexerUri -ApiKey $prowlarrApiKey -Body $payload | Out-Null
        Write-Host "Created Prowlarr indexer: $($payload.name)"
    }
}

Write-Host 'Indexer import complete.'
