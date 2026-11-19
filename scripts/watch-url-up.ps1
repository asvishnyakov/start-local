function Watch-Url-Up {
    # Polls $ApiUrl until it answers 200. Returns $false when it does not within the timeout.
    # $OnFailureLog (for example { docker compose logs --tail 50 vc-platform-web }) runs on every third failed attempt.
    # After WaitSeconds it tries floor(TimeoutMinutes * 60 / RetrySeconds) times (at least once), RetrySeconds apart,
    # so the total time is approximate: the wait and each request's own time come on top.
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$ApiUrl,
        [ValidateRange(1, [int]::MaxValue)]
        [int]$TimeoutMinutes = 15,
        [ValidateRange(1, [int]::MaxValue)]
        [int]$RetrySeconds = 15,
        [ValidateRange(0, [int]::MaxValue)]
        [int]$WaitSeconds = 6,
        [scriptblock]$OnFailureLog
    )

    $printLogAttempt = 3
    [int]$maxRepeat = [Math]::Max(1, [Math]::Floor($TimeoutMinutes * 60 / $RetrySeconds))

    Write-Host "Wait $WaitSeconds seconds before the $ApiUrl status checks." -ForegroundColor Yellow
    Start-Sleep -Seconds $WaitSeconds

    $lastReason = 'no answer'
    for ($attempt = 1; $attempt -le $maxRepeat; $attempt++) {
        Write-Host "Try to open $ApiUrl. Attempt # $attempt of $maxRepeat." -ForegroundColor Yellow
        try {
            $response = Invoke-WebRequest -Uri $ApiUrl -Method Get -SkipCertificateCheck
            if ([int]$response.StatusCode -eq 200) {
                Write-Host "$ApiUrl is up!" -ForegroundColor Green
                return $true
            }
            $lastReason = "status $([int]$response.StatusCode)"
        }
        catch {
            $lastReason = $_.Exception.Message
            if ($OnFailureLog -and $attempt % $printLogAttempt -eq 0) {
                & $OnFailureLog | Out-Host
            }
        }
        if ($attempt -lt $maxRepeat) {
            Start-Sleep -Seconds $RetrySeconds
        }
    }

    Write-Host "$ApiUrl did not answer 200 in time (last: $lastReason). It may be down, please check!" -ForegroundColor Red
    return $false
}
