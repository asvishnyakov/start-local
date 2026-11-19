function Get-AuthToken {
    # Returns the access token, or $null when the platform refuses the sign-in or cannot be reached. Only a refused
    # password is quiet, so that the caller tries its next candidate; every other failure is a warning naming the cause.
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
        $statusCode = [int]$response.StatusCode
        $replyText = [string]$response.Content
    }
    catch {
        $statusCode = if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) { [int]$_.Exception.Response.StatusCode }
        if ($statusCode -ne 400) {
            Write-Warning "Could not sign in at ${AppAuthUrl}: $($_.Exception.Message)"
            return $null
        }
        # The token endpoint answers 400 for every sign-in and request it refuses. Invoke-WebRequest puts the reply body
        # in ErrorDetails (the response content is disposed by then).
        $replyText = [string]$_.ErrorDetails.Message
    }

    # One rule for a 400 and for a 200 that carries no token.
    $reply = ConvertFrom-TokenReply $replyText
    if (-not [string]::IsNullOrWhiteSpace($reply.access_token)) {
        return [string]$reply.access_token
    }

    $oauthError = [string]$reply.error
    $description = [string]$reply.error_description
    if ($oauthError -ceq 'invalid_grant') {
        # The platform answers invalid_grant for every sign-in it refuses and tells them apart by its own code
        # (SecurityErrorDescriber): login_failed is the refused password. Any other code is a refusal no other password
        # gets past: an expired password, or a locked account. The platform names a locked account only with
        # PasswordLogin:DetailedErrors; by default it answers login_failed for one.
        $refusalCode = [string]$reply.code
        if ($refusalCode -and $refusalCode -cne 'login_failed') {
            Write-Warning "Could not sign in at ${AppAuthUrl}: the platform refused the sign-in ($refusalCode), not the password. $description".TrimEnd()
        }
        else {
            Write-Verbose "Get-AuthToken: ${AppAuthUrl} refused the password. $description".TrimEnd()
        }
    }
    elseif ($oauthError) {
        Write-Warning "Could not sign in at ${AppAuthUrl}: the platform rejected the request ($oauthError), not the password. $description".TrimEnd()
    }
    else {
        # Not a reply of the token endpoint. Of JSON only the key names are shown, never the values: they may be tokens.
        # Other text (a proxy error page) is shown from its start, on one line.
        $shown = if ($reply -is [System.Management.Automation.PSCustomObject]) {
            $keys = @($reply.PSObject.Properties.Name)
            "a JSON object with $(if ($keys) { "the keys $($keys -join ', ')" } else { 'no keys' })"
        }
        elseif ($replyText.TrimStart() -match '^[\[{"]') {
            'JSON that is not a token reply'
        }
        else {
            $excerpt = ($replyText -replace '\s+', ' ').Trim()
            if ($excerpt.Length -gt 200) {
                $excerpt = $excerpt.Substring(0, 200) + '...'
            }
            if ($excerpt) { $excerpt } else { 'no body' }
        }
        Write-Warning "Could not sign in at ${AppAuthUrl}: the reply (status $statusCode) has no access token and names no OAuth error: $shown"
    }
    return $null
}

function ConvertFrom-TokenReply {
    # The JSON reply of the token endpoint, or $null when ConvertFrom-Json cannot read it (a proxy error page, no body).
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        $Text | ConvertFrom-Json -ErrorAction Stop
    }
    catch [System.ArgumentException], [System.InvalidOperationException] {
        # ArgumentException: the text is not JSON. InvalidOperationException: an object whose keys differ only in case.
        $null
    }
}
