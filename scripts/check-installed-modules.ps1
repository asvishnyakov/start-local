Param(
    $ApiUrl = 'http://localhost:8090',
    # Admin password from .env, tried first when set; the seeded one (store) is tried next.
    [string]$AdminPassword,
    # The caller (start.ps1) has waited until the platform answers.
    [int]$MinInstalledModules = 23
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/_init.ps1"

$checkModulesUrl = "$ApiUrl/api/platform/modules"

$authToken = Get-AdminToken -ApiUrl $ApiUrl -AdminPassword $AdminPassword
if ([string]::IsNullOrWhiteSpace($authToken)) {
    Write-Host "Error: the platform at $ApiUrl accepts none of the admin passwords." -ForegroundColor Red
    exit 1
}

$headers = @{ Authorization = "Bearer $authToken" }
try {
    $modules = Invoke-RestMethod $checkModulesUrl -Method Get -Headers $headers -SkipCertificateCheck -MaximumRetryCount 5 -RetryIntervalSec 5
}
catch {
    Write-Host "Error: Failed to check modules status at $checkModulesUrl" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
$installedModules = 0
if ($modules.Length -le 0) {
    Write-Host "Error: No module info returned from $checkModulesUrl" -ForegroundColor Red
    exit 1
}
Foreach ($module in $modules) {
    if ($module.isInstalled) {
        Write-Host "`e[32m$($module.id) version $($module.version) is installed"
        $installedModules++
    }
    if ($module.validationErrors.Length -gt 0) {
        Write-Host "Error: Module $($module.id) has validation errors:" -ForegroundColor Red
        Write-Output $module.validationErrors
        exit 1
    }
}
Write-Output "Modules installed: $installedModules"
if ($installedModules -lt $MinInstalledModules) {
    Write-Host "Error: Expected at least $MinInstalledModules installed modules, found $installedModules." -ForegroundColor Red
    exit 1
}

