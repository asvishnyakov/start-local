#Requires -Version 7.4
# Stops the solution folder's Docker stack and removes its containers, and stops a platform run from source. Volumes and images stay.
param (
    [string]$solutionFolder = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/scripts/_init.ps1"

$solutionPath = (Resolve-Path -LiteralPath $solutionFolder -ErrorAction Stop).Path
Push-Location -LiteralPath $solutionPath
try {
    Invoke-StartLocalMigration $solutionPath | Out-Null

    # First, and apart from Docker: the platform run from source has no restart policy and may outlive a failed `down`.
    # A platform that cannot be stopped (InvalidOperationException) does not block `down`: its error is printed after
    # it, whatever becomes of `down`, and stop exits 1.
    $sourceError = $null
    try {
        if (Stop-SourcePlatform -LogDir (Get-SourcePlatformLogDir -SolutionFolder $solutionPath)) {
            Write-Host 'Platform from source stopped' -ForegroundColor Green
        }
    }
    catch [System.InvalidOperationException] {
        $sourceError = $_
    }

    Write-Host 'Stopping VC solution...' -ForegroundColor Yellow
    $downError = $null
    try {
        Invoke-DockerCompose down --remove-orphans
        if ($LASTEXITCODE -ne 0) {
            $downError = "docker compose down failed with exit code $LASTEXITCODE."
        }
    }
    catch [System.InvalidOperationException] {
        # The Compose plugin or the docker command is missing.
        $downError = $_.Exception.Message
    }
    if ($sourceError) {
        Write-ScriptError -ErrorRecord $sourceError
    }
    if ($downError) {
        Write-ScriptError $downError
    }
    if ($sourceError -or $downError) {
        exit 1
    }
    Write-Host '... VC solution stopped' -ForegroundColor Green
}
catch {
    Write-ScriptError -ErrorRecord $_
    exit 1
}
finally {
    Pop-Location
}
