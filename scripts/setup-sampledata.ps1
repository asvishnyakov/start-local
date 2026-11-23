Param(
    [parameter(Mandatory = $true)]
    $ApiUrl,
    $SampleDataSrc,
    # The admin token of the caller (start.ps1), which signs in once per run: Identity locks admin for 15 minutes after
    # 5 failed sign-ins, so this script does not sign in on its own.
    [Parameter(Mandatory)][string]$Token
)

$ErrorActionPreference = "Stop"

$sdStateUrl = "$ApiUrl/api/platform/pushnotifications"
if ([string]::IsNullOrWhiteSpace($SampleDataSrc)) {
    $sdInstallUrl = "$ApiUrl/api/platform/sampledata/autoinstall"
}
else {
    $sdInstallUrl = "$ApiUrl/api/platform/sampledata/import?url=$SampleDataSrc"
}
$headers = @{ Authorization = "Bearer $Token" }

try {
    # Sent once: it starts an import, so a retry after a slow reply could start a second one.
    $installResult = Invoke-RestMethod -Uri $sdInstallUrl -ContentType "application/json" -Method Post -Headers $headers -SkipCertificateCheck
}
catch {
    Write-Host "Error: Failed to start sample data installation at $sdInstallUrl" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
Write-Output $installResult

$notificationId = $installResult.id
if ([string]::IsNullOrEmpty($notificationId)) {
    # The platform answers with an empty 200 when it has nothing to install: sample data is installed already, or none is
    # available. There is no import job to wait for.
    Write-Host 'The platform reports nothing to install (sample data is installed already, or none is available).' -ForegroundColor Green
    exit 0
}
$NotificationStateJson = @"
     {"Ids":["$notificationId"],"start":0, "count": 1}
"@

$notify = @{}
$cycleCount = 0
$maxCycles = 180   # 180 * 3s sleep ≈ 9 minutes
do {
    Start-Sleep -s 3
    try {
        $state = Invoke-RestMethod "$sdStateUrl" -Body $NotificationStateJson -Method Post -ContentType "application/json" -Headers $headers -SkipCertificateCheck
    }
    catch {
        Write-Host "Error: Failed to query sample data installation state at $sdStateUrl" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
    Write-Output $state
    if ($state.notifyEvents -ne $null ) {
        $notify = $state.notifyEvents
        if ($notify.errorCount -gt 0) {
            Write-Output $notify
            Write-Host "`e[31mSample data installation failed."
            exit 1
        }
    }
    $cycleCount++
}
while (([string]::IsNullOrEmpty($notify.finished)) -and $cycleCount -lt $maxCycles)

if ([string]::IsNullOrEmpty($notify.finished)) {
    Write-Host "Error: Sample data installation did not complete within $($maxCycles * 3) seconds." -ForegroundColor Red
    exit 1
}
Write-Host "`e[32mSample data installation complete."
