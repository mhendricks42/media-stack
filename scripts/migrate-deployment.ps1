param(
    [string]$Binary = '.\media-stack.exe',
    [string]$StatePath = 'media-stack.yaml'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path '.env')) {
    throw '.env was not found. Run this helper from the deployment repository.'
}
if (Test-Path $StatePath) {
    throw "$StatePath already exists; it was not overwritten."
}
if (-not (Test-Path $Binary)) {
    throw "media-stack binary was not found: $Binary"
}

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$envBackup = ".env.backup.cli-migration.$timestamp"
$planDirectory = '.media-stack\plans'
$planPath = Join-Path $planDirectory "migration-$timestamp.json"

Copy-Item '.env' $envBackup
New-Item -ItemType Directory -Force -Path $planDirectory | Out-Null

& $Binary adopt --env .env --write $StatePath --output yaml | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Existing deployment adoption failed.'
}

& $Binary plan --state $StatePath --plan-out $planPath
if ($LASTEXITCODE -ne 0) {
    throw 'Migration plan generation failed.'
}

Write-Host ''
Write-Host 'Existing deployment adopted without applying changes.'
Write-Host "Environment backup: $envBackup"
Write-Host "Desired state:      $StatePath"
Write-Host "Reviewable plan:    $planPath"
Write-Host ''
Write-Host 'Review the desired state and plan. Load session secrets before applying:'
Write-Host '  .\stack.ps1 env --include-tailscale'
Write-Host "  $Binary apply --state $StatePath --plan $planPath --yes"
