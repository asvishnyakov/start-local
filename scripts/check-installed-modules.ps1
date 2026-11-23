Param(
    [Parameter(Mandatory)][string]$ApiUrl,
    # The admin token of the caller (start.ps1), which has waited until the platform answers and signed in once: Identity
    # locks admin for 15 minutes after 5 failed sign-ins, so the scripts do not sign in on their own.
    [Parameter(Mandatory)][string]$Token,
    # The modules the platform should load (Get-ExpectedModuleIds); not compared when not given.
    [string[]]$ExpectedModuleIds
)

# Reads the platform's diagnostics, which list only what is installed. The modules list (/api/platform/modules) also
# loads the external modules catalog, so it fails offline or behind a TLS-intercepting proxy.
# There is no minimum count: a solution may hold only a few modules. A module that failed to load is in the errors list.

$ErrorActionPreference = "Stop"

$systemInfoUrl = "$ApiUrl/api/platform/diagnostics/systeminfo"
$errorsUrl = "$ApiUrl/api/platform/diagnostics/errors"

$requestUrl = $systemInfoUrl
try {
    $systemInfo = Invoke-RestMethod $systemInfoUrl -Method Get -Headers @{ Authorization = "Bearer $Token" } -SkipCertificateCheck -MaximumRetryCount 5 -RetryIntervalSec 5
    $requestUrl = $errorsUrl
    # Anonymous. The platform gives the error details in the Development environment only, a generic text otherwise.
    $failedModules = Invoke-RestMethod $errorsUrl -Method Get -SkipCertificateCheck -MaximumRetryCount 5 -RetryIntervalSec 5
}
catch {
    Write-Host "Error: Failed to check modules status at $requestUrl" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

$installedModules = @($systemInfo.installedModules)
if ($installedModules.Count -eq 0) {
    Write-Host "Error: No installed modules reported by $systemInfoUrl" -ForegroundColor Red
    exit 1
}
foreach ($module in $installedModules) {
    Write-Host "`e[32m$($module.id) version $($module.version) is installed"
}

$failedModules = @($failedModules | Where-Object { $_ })
foreach ($module in $failedModules) {
    Write-Host "Error: Module $($module.id) has errors:" -ForegroundColor Red
    Write-Output $module.validationErrors
}
if ($failedModules.Count -gt 0) {
    exit 1
}
$summary = "Modules installed: $($installedModules.Count)"
if ($PSBoundParameters.ContainsKey('ExpectedModuleIds')) {
    # A module the platform never found (a missing folder, a mount that failed) is in neither list above.
    $installedIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($installedModules | ForEach-Object { $_.id }), [System.StringComparer]::OrdinalIgnoreCase)
    $missingIds = @($ExpectedModuleIds | Where-Object { -not $installedIds.Contains($_) } | Sort-Object -Unique)
    if ($missingIds.Count -gt 0) {
        Write-Host "Error: Modules expected but not installed: $($missingIds -join ', ')" -ForegroundColor Red
        exit 1
    }
    $summary += " ($(@($ExpectedModuleIds | Sort-Object -Unique).Count) expected)"
}
Write-Output $summary
