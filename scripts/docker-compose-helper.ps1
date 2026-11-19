# The Compose plugin only (D4): 'docker compose', version 2.18.0 or later (5.x included), never the old docker-compose.

$script:ComposeMinimumVersion = '2.18.0'

function Get-ComposeMissingMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    "'docker compose' (the Compose plugin, $script:ComposeMinimumVersion or later) is not available. Install Docker with Compose $script:ComposeMinimumVersion or later."
}

function Test-DockerCommand {
    # True when the docker CLI is installed: an executable on PATH (an alias or a function of that name does not count).
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    [bool](Get-Command docker -CommandType Application -ErrorAction Ignore)
}

function Invoke-DockerCompose {
    # Runs `docker compose <args>`. Throws when the plugin is missing.
    if (-not (Test-DockerComposeAvailable)) {
        throw [System.InvalidOperationException]::new((Get-ComposeMissingMessage))
    }
    & docker compose @args
}

function Test-DockerComposeAvailable {
    # True when the Compose plugin answers. A positive answer is remembered for the session: Invoke-DockerCompose
    # asks before every call, and the plugin does not go away mid-run.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($script:DockerComposeAvailable) {
        return $true
    }
    if (-not (Test-DockerCommand)) {
        return $false
    }
    $null = & docker compose version 2>&1
    $script:DockerComposeAvailable = $LASTEXITCODE -eq 0
    $script:DockerComposeAvailable
}

function Get-ComposeVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $output = & docker compose version --short 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new("'docker compose version --short' failed: $(ConvertTo-NativeMessage $output "exit code $LASTEXITCODE")")
    }
    $script:DockerComposeAvailable = $true
    # The Docker CLI writes warnings (a broken config.json, ...) to stderr; only stdout is the version.
    (@($output | Select-NativeStdout) -join '').Trim()
}

function Test-ComposeVersion {
    # True when the version is at least the minimum. 'v2.40.3' and '2.18.0-desktop.1' count as 2.40.3 and 2.18.0;
    # text that has no major.minor.patch counts as too old.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Version,
        [Parameter(Position = 1)][string]$Minimum = $script:ComposeMinimumVersion
    )

    $pattern = '^v?(?<core>\d+\.\d+\.\d+)'
    $actual = [regex]::Match($Version.Trim(), $pattern)
    $required = [regex]::Match($Minimum.Trim(), $pattern)
    if (-not $required.Success) {
        throw [System.ArgumentException]::new("'$Minimum' is not a version.", 'Minimum')
    }
    if (-not $actual.Success) {
        return $false
    }
    [version]$actual.Groups['core'].Value -ge [version]$required.Groups['core'].Value
}
