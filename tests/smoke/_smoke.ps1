# Shared by Invoke-Smoke.ps1 and Invoke-MigrationSmoke.ps1: dot-source it after scripts/_init.ps1. Defines functions only.

function Assert-Smoke {
    param(
        [Parameter(Mandatory, Position = 0)][bool]$Condition,
        [Parameter(Mandatory, Position = 1)][string]$Message
    )

    if (-not $Condition) {
        throw [System.InvalidOperationException]::new("Smoke check failed: $Message")
    }
    Write-Host "OK: $Message" -ForegroundColor Green
}

function Assert-OutsideRepository {
    # Entry scripts never run with the repository root as the working directory, and a smoke never writes into it.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ParameterName
    )

    if ($Path.StartsWith($RepositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw [System.ArgumentException]::new("$ParameterName '$Path' is inside the repository '$RepositoryRoot'. Use a scratch folder outside it.", $ParameterName)
    }
}

function Start-ImagePull {
    # CIR items 1 and 3: pull the images in the background while the build downloads and compiles. Interpolation needs
    # the secrets, which are irrelevant to a pull, so they are dummies. The locally built vc-* images exist on no registry
    # (and have no `build:` section to skip them by); without --ignore-pull-failures the failed pull of those would
    # abort the others. A failed pull only warns: `docker compose up` pulls what is missing.
    param(
        [Parameter(Mandatory)][string]$Folder,
        # Arguments for `docker compose` before `pull`: the compose files or env files that select the services.
        [string[]]$ComposeArgument = @()
    )

    # The job runspace does not see this session's variables, so the secret key list travels as an argument.
    Start-Job -ArgumentList $Folder, $ComposeArgument, $script:SecretKeys -ScriptBlock {
        param($Folder, $ComposeArgument, $SecretKeys)

        Set-Location -LiteralPath $Folder
        foreach ($key in $SecretKeys) {
            Set-Item -LiteralPath "env:$key" -Value 'pull-only'
        }
        $output = docker compose @ComposeArgument pull --quiet --ignore-pull-failures 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
    }
}

function Wait-ImagePull {
    # Runs from the smokes' finally blocks, so it never throws: an exception here would turn a passing smoke into a
    # failure and skip the rest of the cleanup. A failed pull only warns (see Start-ImagePull).
    param([AllowNull()][System.Management.Automation.Job]$Job)

    if (-not $Job) {
        return
    }
    try {
        # The job's own errors (a Set-Location that failed, say) come back as error records: collect them, don't rethrow them.
        $pull = Receive-Job -Job $Job -Wait -AutoRemoveJob -ErrorAction SilentlyContinue -ErrorVariable pullErrors
    }
    catch {
        Remove-Job -Job $Job -Force -ErrorAction Ignore
        Write-Warning "The background image pull could not be read: $($_.Exception.Message)"
        return
    }
    foreach ($pullError in $pullErrors) {
        Write-Warning "The background image pull reported: $pullError"
    }
    $result = @($pull | Where-Object { $_.PSObject.Properties.Name -contains 'ExitCode' }) | Select-Object -Last 1
    if (-not $result) {
        Write-Warning 'The background image pull returned no result.'
    }
    elseif ($result.ExitCode -ne 0) {
        Write-Warning "The background image pull exited with code $($result.ExitCode): $($result.Output)"
    }
}

function Write-SmokeDiagnostics {
    # Container state and the last log lines, so a failed CI run can be debugged from its log.
    param([Parameter(Mandatory)][string]$Folder)

    Write-Host 'Container state and the last log lines, for the CI log:' -ForegroundColor Yellow
    if (-not (Test-Path -LiteralPath (Join-Path $Folder 'docker-compose.yml'))) {
        return
    }
    Push-Location -LiteralPath $Folder
    try {
        # A failing docker command does not throw: it sets $LASTEXITCODE, so each call is checked on its own.
        docker compose ps --all
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Could not read the container state: docker compose ps exited with code $LASTEXITCODE." -ForegroundColor Yellow
        }
        docker compose logs --tail 80
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Could not read the container logs: docker compose logs exited with code $LASTEXITCODE." -ForegroundColor Yellow
        }
    }
    catch {
        # A docker command that cannot be run at all (not installed) throws.
        Write-Host "Could not run docker for the diagnostics: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    finally {
        Pop-Location
    }
}

function Invoke-SmokeInstall {
    # The installer in the role the bootstrap gives it (-payloadPath), with the repository as the payload, in-process.
    # With -TranscriptPath, what it writes to the host is also recorded there, for checks on its messages.
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$TranscriptPath
    )

    $installParameters = @{
        payloadPath    = $RepositoryRoot
        targetFolder   = $Target
        nonInteractive = $true
        releaseChannel = 'stable'
    }
    $global:LASTEXITCODE = 0
    if ($TranscriptPath) {
        $null = Start-Transcript -LiteralPath $TranscriptPath -UseMinimalHeader
    }
    try {
        & (Join-Path $RepositoryRoot 'install.ps1') @installParameters
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($TranscriptPath) {
            $null = Stop-Transcript
        }
    }
    Assert-Smoke ($exitCode -eq 0) "install.ps1 exited with code $exitCode"
}

function Test-DockerImage {
    # True when the image exists locally. Throws when the Docker daemon cannot be asked.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $output = docker image ls -q $Name 2>&1
    Assert-NativeSuccess "docker image ls $Name"
    # Only stdout lists image ids; a CLI warning on stderr is not an image.
    -not [string]::IsNullOrWhiteSpace((@($output | Select-NativeStdout) | Out-String))
}
