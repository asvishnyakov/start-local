#Requires -Version 7.4
# Builds the platform and storefront Docker images for the solution folder's release channel.
# Configuration lives in .env; the first-class parameters below are saved into it (SPEC §8). -solutionFolder and the
# per-run switches (-skipSampleData, -nonInteractive) are not.
param (
    [string]$solutionFolder = $PSScriptRoot,
    [string]$releaseChannel,
    [string]$customPackagesJson,
    [string]$customFrontendUrl,
    [Obsolete("Use -releaseChannel")]
    [string]$vcSolutionVersion,
    [bool]$skipSampleData = $false,
    [switch]$nonInteractive
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/scripts/_init.ps1"

function Install-CustomPackageManifest {
    # Copies or downloads the custom package manifest to $DestinationPath and checks it is usable.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if ($Source -match '^https?://') {
        Write-Host "Downloading custom package manifest from $Source..." -ForegroundColor Yellow
        try {
            Invoke-WebRequest -Uri $Source -OutFile $DestinationPath -ErrorAction Stop
        }
        catch {
            throw [System.InvalidOperationException]::new("failed to download custom package manifest from '$Source': $($_.Exception.Message)", $_.Exception)
        }
    }
    else {
        try {
            $resolvedSource = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).Path
        }
        catch {
            throw [System.IO.FileNotFoundException]::new("custom package manifest not found at '$Source'.", $Source)
        }
        Copy-Item -LiteralPath $resolvedSource -Destination $DestinationPath -Force
    }

    # Verify the manifest is well-formed JSON and has the required fields
    try {
        $manifest = Get-Content -Raw -LiteralPath $DestinationPath | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw [System.FormatException]::new("custom package manifest at '$DestinationPath' is not valid JSON: $($_.Exception.Message)", $_.Exception)
    }
    if (-not $manifest.PlatformVersion) {
        throw [System.FormatException]::new("custom package manifest is missing required field 'PlatformVersion'.")
    }
    Write-Host "Custom manifest verified: PlatformVersion = $($manifest.PlatformVersion)" -ForegroundColor Green
    try {
        [void][System.Version]::Parse(($manifest.PlatformVersion -split '-', 2)[0])
    }
    catch {
        Write-Host "Warning: PlatformVersion '$($manifest.PlatformVersion)' may not be parseable by vc-build (System.Version expects numeric major.minor[.build[.revision]] before any prerelease suffix)." -ForegroundColor Yellow
    }
}

function Remove-FolderIfPresent {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

# The manifest path the user typed is relative to where they ran the script, not to the solution folder:
# resolve it before Push-Location so .env stores an absolute path. A relative value already in .env
# keeps resolving against the solution folder (Install-CustomPackageManifest runs after Push-Location).
$callerDirectory = (Get-Location).Path
if ($PSBoundParameters.ContainsKey('customPackagesJson')) {
    $PSBoundParameters['customPackagesJson'] = Resolve-ManifestSource ([string]$customPackagesJson) $callerDirectory
}

$solutionPath = (Resolve-Path -LiteralPath $solutionFolder -ErrorAction Stop).Path
Push-Location -LiteralPath $solutionPath
try {
    Invoke-StartLocalMigration $solutionPath | Out-Null

    $envPath = Join-Path $solutionPath '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        Write-ScriptError "$envPath not found. Run install.ps1 first."
        exit 1
    }
    $document = Read-EnvFile -Path $envPath

    $isNonInteractive = Test-NonInteractive -Switch $nonInteractive.IsPresent -InputRedirected ([Console]::IsInputRedirected) -CiValue ([string]$env:CI)

    foreach ($warning in (Update-EnvFromOptions -Document $document -Bound $PSBoundParameters)) {
        Write-Warning $warning
    }
    $missingKeys = Request-RequiredEnvKeys -Document $document -NonInteractive $isNonInteractive -BaseDirectory $callerDirectory
    Write-EnvFile -Document $document -Path $envPath
    if ($missingKeys.Count -gt 0) {
        Write-ScriptError "set $($missingKeys -join ', ') in $envPath, or pass the matching parameter."
        exit 1
    }

    $channel = ConvertTo-ReleaseChannel -Value (Get-EnvValue -Document $document -Key 'RELEASE_CHANNEL')
    if (-not $channel) {
        Write-ScriptError "RELEASE_CHANNEL '$(Get-EnvValue -Document $document -Key 'RELEASE_CHANNEL')' is not a release channel. Use stable, stable:<N>, edge or custom."
        exit 1
    }
    $bundle = Get-BundleSpec -Channel $channel
    $features = Get-ComposeFeatures (Get-EnvComposeFiles $document)

    $stableJson = $null
    if ($channel.Kind -eq 'stable-n' -or ($features.Frontend -and $bundle.FrontendSource -eq 'bundle')) {
        $stableJson = Get-StableJson
    }
    if ($channel.Kind -eq 'stable-n' -and -not (Test-StableBundleKey $channel.Number $stableJson)) {
        Write-ScriptError "Stable $($channel.Number) is not listed in bundles/stable.json. Check RELEASE_CHANNEL."
        exit 1
    }

    $projectName = Get-SolutionProjectName -Document $document -SolutionFolder $solutionPath

    if ($features.Platform) {
        $backendDir = Join-Path $solutionPath 'backend'
        $publishDir = Join-Path $backendDir 'publish'
        $customPackagesJsonPath = Join-Path $backendDir 'custom-packages.json'
        if (-not (Get-Command vc-build -CommandType Application, ExternalScript -ErrorAction Ignore)) {
            throw [System.InvalidOperationException]::new("'vc-build' is not on PATH. Install it with: dotnet tool install -g VirtoCommerce.GlobalTool")
        }
        if ($channel.Kind -eq 'custom') {
            Install-CustomPackageManifest -Source (Get-EnvValue -Document $document -Key 'CUSTOM_PACKAGES_JSON') -DestinationPath $customPackagesJsonPath
        }

        try {
            Write-Host "Building backend ($($channel.Normalized))..." -ForegroundColor Yellow
            # A modules folder in MODULE_SOURCE_PATHS is bind-mounted over the image's modules, so vc-build installs into it (SPEC §7.3).
            $moduleSources = Get-ModuleSourceKind -Paths (Split-ModuleSourcePaths (Get-EnvValue -Document $document -Key 'MODULE_SOURCE_PATHS'))
            $discoveryPath = Join-Path $publishDir 'modules'
            if ($moduleSources.Kind -eq 'modulesfolder') {
                $discoveryPath = $moduleSources.Entries[0].Path
                Write-Host "Installing the modules into $discoveryPath (MODULE_SOURCE_PATHS)." -ForegroundColor Yellow
            }
            $vcBuildArguments = Get-VcBuildInstallArgs $channel $customPackagesJsonPath $discoveryPath (Join-Path $publishDir 'app_data/modules') $publishDir
            & vc-build @vcBuildArguments
            Assert-NativeSuccess 'vc-build install'
            Write-Host '... Backend built successfully' -ForegroundColor Green

            Write-Host 'Building backend Docker image...' -ForegroundColor Yellow
            Save-PlatformDockerfile -Destination $backendDir
            docker build --no-cache -t "vc-platform:$projectName-latest" $backendDir
            Assert-NativeSuccess 'docker build of the platform image'
            Write-Host '... Backend Docker image built successfully' -ForegroundColor Green
        }
        finally {
            Remove-FolderIfPresent $publishDir
        }
    }

    if ($features.Frontend) {
        $frontendDir = Join-Path $solutionPath 'frontend'
        $frontendZipPath = Join-Path $frontendDir 'frontend.zip'
        $frontendArtifactDir = Join-Path $frontendDir 'artifact'

        $frontendZipUrl = switch ($bundle.FrontendSource) {
            'bundle' { Get-BundleFrontendUrl $bundle.BundleKey $stableJson }
            'latest-release' { Get-LatestFrontendReleaseUrl }
            'custom' {
                $customUrl = Get-EnvValue -Document $document -Key 'CUSTOM_FRONTEND_URL'
                # Prompts only on an interactive run without -customFrontendUrl when .env has no URL yet (an interactive
                # install reaches it too).
                if ([string]::IsNullOrWhiteSpace($customUrl) -and -not $isNonInteractive -and -not $PSBoundParameters.ContainsKey('customFrontendUrl')) {
                    $customUrl = Read-Host 'Enter custom frontend ZIP URL (leave empty to use the latest vc-frontend GitHub release)'
                }
                if ([string]::IsNullOrWhiteSpace($customUrl)) { Get-LatestFrontendReleaseUrl } else { $customUrl.Trim() }
            }
        }

        try {
            Write-Host 'Downloading and extracting frontend files...' -ForegroundColor Yellow
            Remove-FolderIfPresent $frontendArtifactDir
            Invoke-FileDownload $frontendZipUrl $frontendZipPath 'the frontend'
            Expand-Archive -LiteralPath $frontendZipPath -DestinationPath $frontendArtifactDir
            Write-Host '... Frontend files downloaded and extracted' -ForegroundColor Green

            Write-Host 'Building frontend Docker image...' -ForegroundColor Yellow
            docker build -t "vc-frontend:$projectName-latest" $frontendDir
            Assert-NativeSuccess 'docker build of the storefront image'
            Write-Host '... Frontend Docker image built successfully' -ForegroundColor Green
        }
        finally {
            Remove-FolderIfPresent $frontendZipPath
            Remove-FolderIfPresent $frontendArtifactDir
        }
    }

    if ($features.Https) {
        Write-Host 'Exporting the development certificate...' -ForegroundColor Yellow
        $certsDirectory = Join-Path (Join-Path $solutionPath 'backend') 'certs'
        if (-not (Export-DevCertificate -Destination $certsDirectory)) {
            throw [System.InvalidOperationException]::new("The development certificate could not be exported into '$certsDirectory'. Install the .NET SDK (dotnet dev-certs), or switch to HTTP mode with ./start.ps1 -allowInsecureHttp.")
        }
        Write-Host '... Development certificate exported' -ForegroundColor Green
    }

    if (Read-YesNo -Prompt 'Start now?' -Default $true -NonInteractive $isNonInteractive) {
        $startScriptPath = Join-Path $solutionPath 'start.ps1'
        if (-not (Test-Path -LiteralPath $startScriptPath -PathType Leaf)) {
            Write-ScriptError "$startScriptPath not found, so the solution was not started."
            exit 1
        }
        Write-Host 'Starting run process...' -ForegroundColor Yellow
        $startArguments = @{ skipSampleData = $skipSampleData }
        if ($isNonInteractive) {
            $startArguments['nonInteractive'] = $true
        }
        & $startScriptPath @startArguments
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }
    else {
        Write-Host 'Run process skipped. You can run it later with: ./start.ps1' -ForegroundColor Yellow
    }
}
catch {
    Write-ScriptError -ErrorRecord $_
    exit 1
}
finally {
    Pop-Location
}
