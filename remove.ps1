#Requires -Version 7.4
# Removes the solution folder's Docker stack. Full: containers, volumes, images and the folder.
# -keepData: containers, network, images and every file except .env and the user's own compose files in COMPOSE_FILE;
# the volumes stay, and re-running the installer
# over the folder brings the stack back with its data (SPEC §8.1).
param (
    [string]$solutionFolder = $PSScriptRoot,
    [switch]$keepData,
    [switch]$nonInteractive
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/scripts/_init.ps1"

$solutionPath = (Resolve-Path -LiteralPath $solutionFolder -ErrorAction Stop).Path
# Before anything else, even the migration: the repository root is a valid solution folder and must never be removed (P13).
if (-not (Test-RemovableFolder -Folder $solutionPath)) {
    Write-ScriptError "$solutionPath contains .git, so it is a repository checkout. Run remove.ps1 from an installed solution folder."
    exit 1
}
$envPath = Join-Path $solutionPath '.env'
if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    Write-ScriptError "$envPath not found, so $solutionPath is not a start-local solution folder. Nothing was removed."
    exit 1
}
if (-not (Test-DockerComposeAvailable)) {
    Write-ScriptError (Get-ComposeMissingMessage)
    exit 1
}

Push-Location -LiteralPath $solutionPath
try {
    # A layout 1 folder gets VOLUME_PREFIX=virto here, so the plan names its virto_* volumes.
    Invoke-StartLocalMigration $solutionPath | Out-Null
    $plan = Get-RemovalPlan -Folder $solutionPath -KeepData $keepData.IsPresent

    $isNonInteractive = Test-NonInteractive -Switch $nonInteractive.IsPresent -InputRedirected ([Console]::IsInputRedirected) -CiValue ([string]$env:CI)
    if (-not $isNonInteractive) {
        $scope = if ($keepData) { "every file except .env and your own compose files in COMPOSE_FILE, and the containers and images (the volumes stay)" } else { "the containers, the volumes with all their data, the images and the folder" }
        $answer = Read-Host "Remove $scope of $solutionPath? [y/N]"
        if ($answer -notmatch '^\s*y(es)?\s*$') {
            Write-Host 'Nothing was removed.' -ForegroundColor Yellow
            exit 0
        }
    }

    # First, as stop.ps1 does: the pid file goes with the folder, and a platform run from source would be orphaned.
    if (Stop-SourcePlatform -LogDir (Get-SourcePlatformLogDir -SolutionFolder $solutionPath)) {
        Write-Host 'Platform from source stopped' -ForegroundColor Green
    }

    $composeDownRan = Test-Path -LiteralPath (Join-Path $solutionPath 'docker-compose.yml') -PathType Leaf
    if ($composeDownRan) {
        Write-Host 'Removing the Docker containers...' -ForegroundColor Yellow
        Invoke-DockerCompose @($plan.DownArgs)
        if ($LASTEXITCODE -ne 0) {
            # Deleting files or volumes under running containers would orphan them.
            Write-ScriptError "docker compose $($plan.DownArgs -join ' ') failed with exit code $LASTEXITCODE. Nothing else was removed."
            exit 1
        }
        Write-Host '... containers removed' -ForegroundColor Green
    }
    else {
        Write-Host 'No docker-compose.yml in the folder, so there are no containers to remove.' -ForegroundColor DarkYellow
    }

    # Without a daemon nothing below can be removed, and "absent" could not be told from "unreachable". A successful
    # `docker compose down` above has proven it answers.
    $dockerError = if (-not $composeDownRan) { Get-DockerDaemonError }
    if ($dockerError) {
        Write-ScriptError "Docker is not reachable, so nothing else was removed. Start Docker and run remove.ps1 again. Docker says: $dockerError"
        exit 1
    }

    # Safety net: compose's own `down -v` removes the volumes the active files declare; this removes the rest by name.
    $leftovers = [System.Collections.Generic.List[string]]::new()
    foreach ($volume in $plan.Volumes) {
        $reason = Remove-DockerResource -Kind volume -Name $volume
        if ($reason) { $leftovers.Add("volume ${volume}: $reason") }
    }
    foreach ($image in $plan.Images) {
        $reason = Remove-DockerResource -Kind image -Name $image
        if ($reason) { $leftovers.Add("image ${image}: $reason") }
    }
    if ($leftovers.Count -gt 0) {
        # .env and the folder stay, so the next run of remove.ps1 finds the same names.
        Write-ScriptError "These could not be removed, so the files and .env are kept:"
        foreach ($leftover in $leftovers) { Write-Host "  $leftover" -ForegroundColor Red }
        exit 1
    }
}
catch {
    Write-ScriptError -ErrorRecord $_
    exit 1
}
finally {
    # Leave the folder first: it may be about to be deleted.
    Pop-Location
}

try {
    Write-Host 'Removing files...' -ForegroundColor Yellow
    # Run from inside the folder, the current location is inside the folder being deleted, which PowerShell refuses to remove.
    $currentPath = (Get-Location).ProviderPath
    if (-not $keepData -and ($currentPath -eq $solutionPath -or $currentPath.StartsWith($solutionPath.TrimEnd('/', '\') + [System.IO.Path]::DirectorySeparatorChar))) {
        Set-Location -LiteralPath (Split-Path -Parent $solutionPath)
    }
    foreach ($path in $plan.DeletePaths) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    }
}
catch {
    Write-ScriptError "Failed to remove files from '$solutionPath': $($_.Exception.Message)"
    exit 1
}

if ($keepData) {
    Write-Host "... Done. The volumes and $envPath are kept; run install.ps1 over the folder to restore the stack." -ForegroundColor Green
}
else {
    Write-Host '... Done' -ForegroundColor Green
}
