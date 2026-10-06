# Quick verification script
Write-Host "=== Verifying Image Tags Branch ==="
$imageTags = git show security/pin-image-tags:docker-compose.yml | Select-String "image:"
Write-Host "Image tags found:"
$imageTags | ForEach-Object { Write-Host "  $_" }

$latestCount = ($imageTags | Select-String ":latest").Count
if ($latestCount -eq 0) {
    Write-Host "✅ PASS: No :latest tags found" -ForegroundColor Green
} else {
    Write-Host "❌ FAIL: Found $latestCount :latest tags" -ForegroundColor Red
}

Write-Host "`n=== Verifying CI Workflow Branch ==="
$workflowExists = git cat-file -e ci/compose-validation:.github/workflows/compose-validate.yml 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ PASS: Workflow file exists" -ForegroundColor Green
    $workflowContent = git show ci/compose-validation:.github/workflows/compose-validate.yml
    
    # Check for key validation steps
    if ($workflowContent -match "latest") {
        Write-Host "✅ PASS: Workflow checks for :latest tags" -ForegroundColor Green
    }
    if ($workflowContent -match "healthcheck") {
        Write-Host "✅ PASS: Workflow checks for healthcheck" -ForegroundColor Green
    }
} else {
    Write-Host "❌ FAIL: Workflow file not found" -ForegroundColor Red
}

Write-Host "`n=== Verifying Healthcheck Branch ==="
$healthcheckContent = git show fix/gluetun-healthcheck:docker-compose.yml | Select-String -Pattern "healthcheck" -Context 0,5
if ($healthcheckContent -match "test.*wget" -and $healthcheckContent -notmatch "#.*healthcheck") {
    Write-Host "✅ PASS: Healthcheck is uncommented and active" -ForegroundColor Green
} else {
    Write-Host "❌ FAIL: Healthcheck issue detected" -ForegroundColor Red
}

Write-Host "`n=== Verifying VPN Credentials Branch ==="
$vpnContent = git show security/vpn-credentials-file-pattern:docker-compose.yml | Select-String "OPENVPN"
$hasFilePattern = $vpnContent -match "OPENVPN_USER_FILE"
$hasPasswordFile = $vpnContent -match "OPENVPN_PASSWORD_FILE"
if ($hasFilePattern -and $hasPasswordFile) {
    Write-Host "✅ PASS: VPN credentials use file-based pattern" -ForegroundColor Green
} else {
    Write-Host "❌ FAIL: VPN credentials pattern not found" -ForegroundColor Red
}
