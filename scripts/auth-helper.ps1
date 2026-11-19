function Get-AuthToken {
    # Returns the access token, or $null when the platform refuses the sign-in or cannot be reached.
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$AppAuthUrl,
        [Parameter(Mandatory, Position = 1)]
        [string]$Username,
        [Parameter(Mandatory, Position = 2)]
        [string]$Password
    )

    # No retries: callers wait for the platform first (start.ps1 runs Watch-Url-Up before any sign-in), and a refused
    # (400) sign-in must not be repeated, or the platform lockout could block the admin before the next candidate.
    $body = @{ username = $Username; password = $Password; grant_type = 'password' }
    try {
        $response = Invoke-WebRequest -Uri $AppAuthUrl -Method Post -ContentType 'application/x-www-form-urlencoded' -Body $body -SkipCertificateCheck
        $responseContent = $response.Content | ConvertFrom-Json
    }
    catch {
        $statusCode = if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) { [int]$_.Exception.Response.StatusCode }
        if ($statusCode -eq 400) {
            # A refused sign-in (invalid_grant): the caller tries the next candidate.
            Write-Verbose "Get-AuthToken: ${AppAuthUrl} refused the sign-in: $($_.Exception.Message)"
        }
        else {
            Write-Warning "Could not sign in at ${AppAuthUrl}: $($_.Exception.Message)"
        }
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($responseContent.access_token)) {
        Write-Verbose "Get-AuthToken: the response from $AppAuthUrl has no access_token."
        return $null
    }

    return [string]$responseContent.access_token
}
