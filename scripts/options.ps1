# Script parameters -> .env, the run mode, and the required .env keys.
#
# install, build and start hand their $PSBoundParameters to Update-EnvFromOptions, which persists whichever
# first-class parameters (SPEC §8) each script declares. Per-run switches (-installSampleData, -nonInteractive,
# -keepData) and the folder parameters are never written to .env.

$script:RequiredKeyOrder = 'COMPOSE_FILE', 'RELEASE_CHANNEL', 'CUSTOM_PACKAGES_JSON'
$script:SkipSwitchFeatures = [ordered]@{
    skipFrontend      = 'frontend'
    skipElasticsearch = 'elasticsearch'
    skipKibana        = 'kibana'
    skipRedis         = 'redis'
}

function Update-EnvFromOptions {
    # Applies the bound first-class parameters to the document; returns warnings for the user.
    # COMPOSE_FILE is rewritten through Update-ComposeFileList. A change of HTTP/HTTPS mode moves
    # FRONTEND_PORT between the two standard ports (P17); any other value is the user's.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][System.Collections.IDictionary]$Bound
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    # Keys, not Contains/ContainsKey: $PSBoundParameters, hashtables and ordered dictionaries each offer a different method.
    $isBound = { param($name) $Bound.Keys -contains $name }
    $enabled = { param($name) [bool]$Bound[$name] }

    $simpleKeys = [ordered]@{
        branch               = 'START_LOCAL_REF'
        elasticsearchVersion = 'STACK_VERSION'
        customPackagesJson   = 'CUSTOM_PACKAGES_JSON'
        customFrontendUrl    = 'CUSTOM_FRONTEND_URL'
    }
    foreach ($name in $simpleKeys.Keys) {
        if (& $isBound $name) {
            Set-EnvValue -Document $Document -Key $simpleKeys[$name] -Value ([string]$Bound[$name])
        }
    }

    # -vcSolutionVersion is the obsolete name of -releaseChannel; the new one wins when both are given.
    $channelParameter = if (& $isBound 'releaseChannel') { 'releaseChannel' } elseif (& $isBound 'vcSolutionVersion') { 'vcSolutionVersion' }
    if ($channelParameter) {
        $channel = ConvertTo-ReleaseChannel -Value ([string]$Bound[$channelParameter])
        if (-not $channel) {
            throw [System.ArgumentException]::new("'$($Bound[$channelParameter])' is not a release channel. Use stable, stable:<N>, edge or custom.", $channelParameter)
        }
        Set-EnvValue -Document $Document -Key 'RELEASE_CHANNEL' -Value $channel.Normalized
        foreach ($warning in $channel.Warnings) {
            $warnings.Add($warning)
        }
    }

    # -skipPlatform: no platform at all, Docker or source (SKIP_PLATFORM). Docker's platform.yml follows below.
    if (& $isBound 'skipPlatform') {
        Set-EnvValue -Document $Document -Key 'SKIP_PLATFORM' -Value $(if (& $enabled 'skipPlatform') { 'true' } else { '' })
    }

    $composeParameters = @('dbProvider', 'allowInsecureHttp') + @($script:SkipSwitchFeatures.Keys)
    $composeBound = @($composeParameters | Where-Object { & $isBound $_ })

    $files = Get-EnvComposeFiles $Document
    $dockerPlatform = (Get-PlatformMode (Get-EnvTable -Document $Document)) -eq 'docker'
    $platformListed = $files -ccontains (Get-ComposeFileName 'platform.yml')
    if ($composeBound.Count -eq 0 -and ($files.Count -eq 0 -or $platformListed -eq $dockerPlatform)) {
        # Nothing to change: a COMPOSE_FILE the user wrote keeps its order.
        return , $warnings.ToArray()
    }

    if (& $isBound 'dbProvider') {
        $provider = ([string]$Bound['dbProvider']).ToLowerInvariant()
        $files = if ($files.Count -eq 0) {
            Get-DefaultComposeFiles -Provider $provider
        }
        else {
            Set-ComposeProvider -ComposeFiles $files -Provider $provider
        }
    }
    elseif ($files.Count -eq 0) {
        $warnings.Add("COMPOSE_FILE is empty, so -$($composeBound -join ', -') could not be applied. Choose a database provider, then run again.")
        return , $warnings.ToArray()
    }

    $httpsBefore = $files -ccontains $script:ComposeHttpsFile
    if (& $isBound 'allowInsecureHttp') {
        $files = Set-ComposeHttps -ComposeFiles $files -Enabled (-not (& $enabled 'allowInsecureHttp'))
    }
    foreach ($name in $script:SkipSwitchFeatures.Keys) {
        if (& $isBound $name) {
            $files = Set-ComposeFeature -ComposeFiles $files -Feature $script:SkipSwitchFeatures[$name] -Enabled (-not (& $enabled $name))
        }
    }
    # The Docker platform is listed exactly when the platform runs in Docker, whatever edited .env or the switches.
    $files = Set-ComposeFeature -ComposeFiles $files -Feature 'platform' -Enabled $dockerPlatform
    Set-EnvValue -Document $Document -Key 'COMPOSE_FILE' -Value (ConvertTo-ComposeFileValue $files (Get-ComposeSeparator $Document))

    $httpsAfter = $files -ccontains $script:ComposeHttpsFile
    $standardPortBefore = Get-PortDefault 'FRONTEND_PORT' -Https $httpsBefore
    if ($httpsAfter -ne $httpsBefore -and (Get-EnvValue -Document $Document -Key 'FRONTEND_PORT') -eq $standardPortBefore) {
        Set-EnvValue -Document $Document -Key 'FRONTEND_PORT' -Value (Get-PortDefault 'FRONTEND_PORT' -Https $httpsAfter)
    }

    , $warnings.ToArray()
}

function Test-NonInteractive {
    # A run is non-interactive with -nonInteractive, when stdin is redirected, or when CI=true (B4).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][bool]$Switch,
        [Parameter(Mandatory)][bool]$InputRedirected,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CiValue
    )

    $Switch -or $InputRedirected -or $CiValue.Trim() -eq 'true'
}

function Get-MissingRequiredKeys {
    # The required .env keys (P12) that are empty: COMPOSE_FILE and RELEASE_CHANNEL, plus
    # CUSTOM_PACKAGES_JSON on the custom channel. -ForStart: COMPOSE_FILE only (start never reads the channel).
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvValues,
        [switch]$ForStart
    )

    $isEmpty = { param($key) [string]::IsNullOrWhiteSpace([string]$EnvValues[$key]) }
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($key in 'COMPOSE_FILE', 'RELEASE_CHANNEL') {
        if (& $isEmpty $key) {
            $missing.Add($key)
        }
    }
    if ($ForStart) {
        return , [string[]]@($missing | Where-Object { $_ -eq 'COMPOSE_FILE' })
    }
    $channel = ConvertTo-ReleaseChannel -Value ([string]$EnvValues['RELEASE_CHANNEL'])
    if ($channel -and $channel.Kind -eq 'custom' -and (& $isEmpty 'CUSTOM_PACKAGES_JSON')) {
        $missing.Add('CUSTOM_PACKAGES_JSON')
    }
    , $missing.ToArray()
}

function Request-RequiredEnvKeys {
    # Asks once for each empty required key and saves valid answers. Returns the keys still missing:
    # all of them when non-interactive (the caller fails and names them), else those with an unusable answer.
    # A relative manifest path is stored absolute against -BaseDirectory, the directory the user ran the script from.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][psobject]$Document,
        [Parameter(Mandatory)][bool]$NonInteractive,
        [string]$BaseDirectory = (Get-Location).ProviderPath,
        [switch]$ForStart
    )

    # Assigned first: the function returns its array wrapped (unary comma), and the assignment unwraps it.
    $getMissing = { $keys = Get-MissingRequiredKeys -EnvValues (Get-EnvTable -Document $Document) -ForStart:$ForStart; $keys }
    if ($NonInteractive) {
        return , [string[]]@(& $getMissing)
    }

    foreach ($key in $script:RequiredKeyOrder) {
        # Evaluated per key: the channel answer decides whether CUSTOM_PACKAGES_JSON is required.
        if ((& $getMissing) -notcontains $key) {
            continue
        }
        switch ($key) {
            'COMPOSE_FILE' {
                $answer = (Read-Host 'Database provider: 1 = postgres, 2 = mysql, 3 = sqlserver [1]').Trim()
                $choice = if ($answer -eq '') { 1 } elseif ($answer -match '^[123]$') { [int]$answer } else { 0 }
                if ($choice -eq 0) {
                    Write-Warning "'$answer' is not a database provider choice."
                    continue
                }
                $files = Get-DefaultComposeFiles -Provider $script:DbProviders[$choice - 1] -Https $true
                # The Docker platform is listed exactly when the platform runs in Docker (as Update-EnvFromOptions keeps it).
                $files = Set-ComposeFeature -ComposeFiles $files -Feature 'platform' -Enabled ((Get-PlatformMode (Get-EnvTable -Document $Document)) -eq 'docker')
                Set-EnvValue -Document $Document -Key $key -Value (ConvertTo-ComposeFileValue $files (Get-ComposeSeparator $Document))
            }
            'RELEASE_CHANNEL' {
                $answer = (Read-Host 'Release channel: stable, stable:<N>, edge or custom [stable]').Trim()
                $channel = ConvertTo-ReleaseChannel -Value $(if ($answer -eq '') { 'stable' } else { $answer })
                if (-not $channel) {
                    Write-Warning "'$answer' is not a release channel."
                    continue
                }
                foreach ($warning in $channel.Warnings) {
                    Write-Warning $warning
                }
                Set-EnvValue -Document $Document -Key $key -Value $channel.Normalized
            }
            'CUSTOM_PACKAGES_JSON' {
                $answer = (Read-Host 'Path or URL of the package manifest for the custom channel').Trim()
                if ($answer -ne '') {
                    Set-EnvValue -Document $Document -Key $key -Value (Resolve-ManifestSource $answer $BaseDirectory)
                }
            }
        }
    }

    , [string[]]@(& $getMissing)
}

function Read-YesNo {
    # Asks a yes/no question; an empty answer, or a non-interactive run, gives the default. Any other answer asks again.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][bool]$Default,
        [Parameter(Mandatory)][bool]$NonInteractive
    )

    if ($NonInteractive) {
        return $Default
    }
    while ($true) {
        $answer = (Read-Host "$Prompt $(if ($Default) { '[Y/n]' } else { '[y/N]' })").Trim()
        switch -Regex ($answer) {
            '^$' { return $Default }
            '^(y|yes)$' { return $true }
            '^(n|no)$' { return $false }
            default { Write-Warning "'$answer' is not y or n." }
        }
    }
}

function Resolve-ManifestSource {
    # Makes a relative custom-manifest path absolute against $BaseDirectory (the caller's directory), so
    # .env stores a path that works from any folder. URLs and empty values are returned as given; any path, absolute
    # or relative, comes back trimmed and normalized.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory, Position = 1)][string]$BaseDirectory
    )

    $trimmed = $Value.Trim()
    if ($trimmed -eq '' -or $trimmed -match '^https?://') {
        return $Value
    }
    [System.IO.Path]::GetFullPath($trimmed, $BaseDirectory)
}
