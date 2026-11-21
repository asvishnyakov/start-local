#Requires -Version 7.4
# Installs or updates start-local in -targetFolder. Re-run it to update (SPEC §4.3).
# Two roles (SPEC §4.2): without -payloadPath it is the bootstrap, which downloads the release and delegates to the
# install.ps1 inside it; with -payloadPath it is the payload installer, whose logic is Invoke-PayloadInstall in scripts/payload.ps1.
param (
    [string]$targetFolder = 'VirtoLocal',
    # A branch or a tag of start-local. -branch (its name before 2.0) and -tag are aliases.
    [Alias('branch', 'tag')]
    [string]$ref,
    [ValidateSet('postgres', 'mysql', 'sqlserver')]
    [string]$dbProvider,
    [string]$releaseChannel,
    [string]$customPackagesJson,
    [string]$customFrontendUrl,
    [switch]$allowInsecureHttp,
    # --- Skip parts ---
    [switch]$skipPlatform,
    [switch]$skipFrontend,
    [switch]$skipElasticsearch,
    [switch]$skipKibana,
    [switch]$skipRedis,
    # --- Per run ---
    # Sample data is opt-in: the platform imports it into any database that never had it, an existing one included.
    [switch]$installSampleData,
    [switch]$nonInteractive,
    # --- Obsolete ---
    [Obsolete("Use -releaseChannel")]
    [string]$vcSolutionVersion,
    [Obsolete("Set STACK_VERSION in .env")]
    [string]$elasticsearchVersion,
    [Parameter(DontShow)]
    [string]$payloadPath
)

$script:StartLocalRepository = 'VirtoCommerce/start-local'

function Resolve-ReleaseRef {
    # The ref to install: -Ref as given, or the tag of the latest release (A7). One unauthenticated API call.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)][string]$Ref
    )

    if ($Ref) {
        return [pscustomobject]@{ Ref = $Ref }
    }

    $uri = "https://api.github.com/repos/$script:StartLocalRepository/releases/latest"
    try {
        $release = Invoke-RestMethod -Uri $uri -Headers @{ Accept = 'application/vnd.github+json' } -UserAgent 'start-local-installer'
    }
    catch {
        throw [System.InvalidOperationException]::new("Could not look up the latest start-local release ($uri): $($_.Exception.Message). Pass -ref <ref> to skip the lookup.", $_.Exception)
    }
    if (-not $release.tag_name) {
        throw [System.InvalidOperationException]::new("The latest start-local release has no tag name ($uri). Pass -ref <ref> to choose a ref.")
    }

    [pscustomobject]@{ Ref = [string]$release.tag_name }
}

function Get-PayloadZipUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Ref
    )

    # GitHub resolves archive/<ref>.zip for a branch (slash included) or a tag alike.
    "https://github.com/$script:StartLocalRepository/archive/$Ref.zip"
}

function Get-PayloadRoot {
    # A GitHub archive holds one top-level folder, start-local-<ref>.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$ExtractDir
    )

    $folders = @(Get-ChildItem -LiteralPath $ExtractDir -Directory -Force)
    if ($folders.Count -ne 1) {
        throw [System.InvalidOperationException]::new("Expected one top-level folder in the downloaded archive, found $($folders.Count) in '$ExtractDir'.")
    }

    $folders[0].FullName
}

function Get-LegacyInstallerMessage {
    # A10: the bootstrap installs layout-2 payloads only. A ref without install.ps1 belongs to the old installer.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Ref
    )

    # The ref-agnostic form serves a branch and a tag alike; refs/heads/ would 404 on a tag such as v1.0.0.
    $rawUrl = "https://raw.githubusercontent.com/$script:StartLocalRepository/$Ref/VirtoLocal_create_local_files.ps1"
    @(
        "'$Ref' has no install.ps1: it is the old start-local layout, which this installer does not install."
        "To install that layout, download its own installer and run it:"
        "  Invoke-WebRequest $rawUrl -OutFile VirtoLocal_create_local_files.ps1; ./VirtoLocal_create_local_files.ps1 -branch $Ref"
        "To install the current version, run this installer without -ref."
    ) -join [Environment]::NewLine
}

# Dot-sourcing (the tests) loads the functions above and runs nothing.
if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'

if ($payloadPath) {
    . "$payloadPath/scripts/_init.ps1"

    try {
        $isNonInteractive = Test-NonInteractive -Switch $nonInteractive.IsPresent -InputRedirected ([Console]::IsInputRedirected) -CiValue ([string]$env:CI)
        $exitCode = Invoke-PayloadInstall -PayloadPath $payloadPath -TargetFolder $targetFolder -Bound $PSBoundParameters -NonInteractive $isNonInteractive
    }
    catch {
        Write-ScriptError -ErrorRecord $_
        exit 1
    }
    exit $exitCode
}

try {
    $release = Resolve-ReleaseRef -Ref $ref
    $workFolder = Join-Path ([System.IO.Path]::GetTempPath()) "start-local-$([guid]::NewGuid().ToString('N'))"
    try {
        $null = New-Item -ItemType Directory -Path $workFolder
        $zipPath = Join-Path $workFolder 'payload.zip'
        $zipUrl = Get-PayloadZipUrl -Ref $release.Ref
        Write-Host "Downloading start-local $($release.Ref)..." -ForegroundColor Cyan
        $previousProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
        }
        finally {
            $ProgressPreference = $previousProgress
        }

        $extractDir = Join-Path $workFolder 'payload'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir
        $payloadRoot = Get-PayloadRoot -ExtractDir $extractDir

        $payloadInstaller = Join-Path $payloadRoot 'install.ps1'
        if (-not (Test-Path -LiteralPath $payloadInstaller -PathType Leaf)) {
            throw [System.InvalidOperationException]::new((Get-LegacyInstallerMessage -Ref $release.Ref))
        }

        # The installer that runs always matches its payload (SPEC 4.2): hand over the bound parameters, the payload and the resolved ref.
        $forwarded = @{} + $PSBoundParameters
        $forwarded['payloadPath'] = $payloadRoot
        $forwarded['ref'] = $release.Ref
        & $payloadInstaller @forwarded
        $exitCode = $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $workFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
exit $exitCode
