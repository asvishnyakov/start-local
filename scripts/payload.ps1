# The payload: the files a release delivers into a solution folder. install.ps1 copies them; .env is never one of them.

function Get-PayloadAllowlist {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    # Entries are paths relative to the payload root; a trailing '/' marks a folder. A folder the payload lacks is skipped.
    , [string[]]@(
        'install.ps1', 'build.ps1', 'start.ps1', 'stop.ps1', 'remove.ps1',
        '.env.example', 'docker-compose.yml',
        'docker-compose/', 'scripts/', 'backend/', 'frontend/'
    )
}

function Get-LegacyComposeFileNames {
    # The layout-1 provider files, which lived beside docker-compose.yml. Their layout-2 copies are in docker-compose/,
    # so the payload deletes these from a folder it installs into; no other root compose file is touched.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    'docker-compose.postgres.yml', 'docker-compose.mysql.yml', 'docker-compose.sqlserver.yml'
}

function Get-LegacyScriptNames {
    # The old-named scripts (A5): in this payload they are guards that explain the rename and stop.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    'build-VC-solution.ps1', 'start-VC-solution.ps1', 'stop-VC-solution.ps1', 'remove-VC-solution.ps1'
}

function Copy-Payload {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Root,
        [Parameter(Mandatory, Position = 1)][string]$Destination
    )

    $rootPath = (Resolve-Path -LiteralPath $Root).ProviderPath
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $destinationPath = (Resolve-Path -LiteralPath $Destination).ProviderPath

    $allowlist = Get-PayloadAllowlist
    foreach ($entry in $allowlist) {
        if ($entry.EndsWith('/')) {
            $folder = Join-Path $rootPath $entry.TrimEnd('/')
            if (Test-Path -LiteralPath $folder -PathType Container) {
                Copy-Item -LiteralPath $folder -Destination $destinationPath -Recurse -Force
            }
            continue
        }

        # -LiteralPath keeps '[' and ']' in the payload root literal; -Filter matches the entry by file name, in the root only.
        # No entry can match .env, which is the user's configuration: the payload never writes it.
        foreach ($file in Get-ChildItem -LiteralPath $rootPath -Filter $entry -File -Force) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destinationPath $file.Name) -Force
        }
    }

    foreach ($name in Get-LegacyComposeFileNames) {
        $legacy = Join-Path $destinationPath $name
        if (Test-Path -LiteralPath $legacy -PathType Leaf) {
            Remove-Item -LiteralPath $legacy -Force
        }
    }

    # A5: a folder that already has an old-named script gets its guard; a folder without one never does.
    foreach ($name in Get-LegacyScriptNames) {
        $guard = Join-Path $rootPath $name
        $existing = Join-Path $destinationPath $name
        if ((Test-Path -LiteralPath $existing -PathType Leaf) -and (Test-Path -LiteralPath $guard -PathType Leaf)) {
            Copy-Item -LiteralPath $guard -Destination $existing -Force
        }
    }
}

function Update-VcBuildTool {
    # Installs or updates vc-build. $false (with a warning) when it could not: build.ps1 reports a missing vc-build itself.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Get-Command dotnet -CommandType Application -ErrorAction Ignore)) {
        Write-Warning "The 'dotnet' CLI is not on PATH, so vc-build was not updated. Install the .NET SDK."
        return $false
    }
    # Out-Host keeps the tool's output out of the return value.
    & dotnet tool update --global VirtoCommerce.GlobalTool | Out-Host
    $LASTEXITCODE -eq 0
}

function Invoke-SolutionBuild {
    # Runs the folder's build.ps1 with the per-run switches only (SPEC §4.3 step 8). Returns its exit code.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$TargetFolder,
        [Parameter(Mandatory, Position = 1)][bool]$SkipSampleData,
        [Parameter(Mandatory, Position = 2)][bool]$NonInteractive
    )

    $solutionPath = (Resolve-Path -LiteralPath $TargetFolder).ProviderPath
    $buildScript = Join-Path $solutionPath 'build.ps1'
    if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("build.ps1 is not in '$solutionPath'; the payload did not deliver it.", $buildScript)
    }

    $arguments = @{ solutionFolder = $solutionPath; skipSampleData = $SkipSampleData }
    if ($NonInteractive) {
        $arguments['nonInteractive'] = $true
    }
    $global:LASTEXITCODE = 0
    # Out-Host: vc-build's output stays visible and out of the return value.
    & $buildScript @arguments | Out-Host
    [int]$LASTEXITCODE
}

function Invoke-PayloadInstall {
    # SPEC §4.3: copy the payload, create and migrate .env, fill secrets, apply the parameters, ask for the
    # required keys, ask the per-run questions, run build.ps1. Returns the exit code of the run.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$PayloadPath,
        [Parameter(Mandatory, Position = 1)][string]$TargetFolder,
        [Parameter(Mandatory, Position = 2)][System.Collections.IDictionary]$Bound,
        [Parameter(Mandatory, Position = 3)][bool]$NonInteractive
    )

    # Copy into a hashtable: $Bound may be $PSBoundParameters, a hashtable or an ordered dictionary.
    $options = @{}
    foreach ($name in $Bound.Keys) {
        $options[$name] = $Bound[$name]
    }
    # A relative manifest path is relative to where the user ran the installer; .env stores an absolute one.
    $callerDirectory = (Get-Location).ProviderPath
    if ($options.Keys -contains 'customPackagesJson') {
        $options['customPackagesJson'] = Resolve-ManifestSource ([string]$options['customPackagesJson']) $callerDirectory
    }

    # 0. A layout-1 .env that cannot migrate fails here, before the copy replaces the old scripts with guards.
    $existingEnvPath = Join-Path $TargetFolder '.env'
    if (Test-Path -LiteralPath $existingEnvPath -PathType Leaf) {
        $existingDocument = Read-EnvFile -Path $existingEnvPath
        if ((Get-EnvLayout -Document $existingDocument) -lt 2) {
            $null = Convert-EnvToLayout2 -Document $existingDocument -Template (Read-EnvFile -Path (Join-Path $PayloadPath '.env.example'))
        }
    }

    # An earlier install (layout 2 or 1) left its start script; a .env a wrapper wrote beforehand is not an install.
    $isUpdate = @('start.ps1', 'start-VC-solution.ps1' | Where-Object { Test-Path -LiteralPath (Join-Path $TargetFolder $_) -PathType Leaf }).Count -gt 0

    # 1. Copy the payload. It never touches .env; the guards replace the old-named scripts the folder already has.
    Write-Host 'Copying the start-local files...' -ForegroundColor Yellow
    Copy-Payload -Root $PayloadPath -Destination $TargetFolder
    $solutionPath = (Resolve-Path -LiteralPath $TargetFolder).ProviderPath
    $envPath = Join-Path $solutionPath '.env'
    $templatePath = Join-Path $solutionPath '.env.example'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("The payload at '$PayloadPath' has no .env.example.", $templatePath)
    }

    # 2. Create .env only when the folder has none (B2).
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        Copy-Item -LiteralPath $templatePath -Destination $envPath
        Write-Host 'Created .env from .env.example' -ForegroundColor Green
    }

    # A .env written beforehand (a cloud wrapper) has no layout marker. Get-EnvLayout counts it as layout 2 when it sets
    # COMPOSE_FILE and no DB_PROVIDER (R35); a layout-1 file never sets COMPOSE_FILE. A layout-2 file gets the keys it
    # lacks from .env.example (and the marker, when it had none), and no migration; its existing values, empty or not,
    # are kept here. Every other file without a marker is left to the migration below, untouched.
    $document = Read-EnvFile -Path $envPath
    $unmarked = [string]::IsNullOrWhiteSpace((Get-EnvValue -Document $document -Key 'START_LOCAL_LAYOUT'))
    if ((Get-EnvLayout -Document $document) -ge 2) {
        $added = Add-MissingEnvKeys -Document $document -Template (Read-EnvFile -Path $templatePath)
        if ($unmarked) {
            Set-EnvValue -Document $document -Key 'START_LOCAL_LAYOUT' -Value '2'
        }
        if ($added.Count -gt 0 -or $unmarked) {
            Write-EnvFile -Document $document -Path $envPath
        }
    }

    # 3. Migrate (SPEC §9). A migrated folder must be rebuilt: its 1.x images do not fit the layout-2 compose files.
    $migration = Invoke-StartLocalMigration $solutionPath
    $mustBuild = $null -ne $migration -and $migration.Changes.Count -gt 0
    $document = Read-EnvFile -Path $envPath
    # remove -keepData leaves .env and the volumes, no script: an existing database volume is an earlier install too.
    $isUpdate = $isUpdate -or (Test-SolutionDatabaseVolume -Document $document -SolutionFolder $solutionPath)

    # 4. Fill the empty secrets; filled ones are never rotated.
    $filled = Update-EnvSecrets -Document $document -SecretKeys $script:SecretKeys
    if ($filled.Count -gt 0) {
        Write-Host "Generated $($filled -join ', ')" -ForegroundColor Green
    }

    # 5. Apply the first-class parameters. With no COMPOSE_FILE yet and no -dbProvider, the switches that rewrite it
    # wait for the answer to the provider question (step 6); Update-EnvFromOptions cannot apply them to an empty list.
    $composeSwitches = @('allowInsecureHttp') + @($script:SkipSwitchFeatures.Keys)
    $deferred = @{}
    if ([string]::IsNullOrWhiteSpace((Get-EnvValue -Document $document -Key 'COMPOSE_FILE')) -and $options.Keys -notcontains 'dbProvider') {
        foreach ($name in @($options.Keys | Where-Object { $composeSwitches -contains $_ })) {
            $deferred[$name] = $options[$name]
            $options.Remove($name)
        }
    }
    foreach ($warning in (Update-EnvFromOptions -Document $document -Bound $options)) {
        Write-Warning $warning
    }

    # 6. Ask once for each empty required key; a non-interactive run fails and names them.
    $missingKeys = Request-RequiredEnvKeys -Document $document -NonInteractive $NonInteractive -BaseDirectory $callerDirectory
    if ($deferred.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace((Get-EnvValue -Document $document -Key 'COMPOSE_FILE'))) {
        foreach ($warning in (Update-EnvFromOptions -Document $document -Bound $deferred)) {
            Write-Warning $warning
        }
    }
    Write-EnvFile -Document $document -Path $envPath
    if ($missingKeys.Count -gt 0) {
        Write-ScriptError "set $($missingKeys -join ', ') in $envPath, or pass the matching parameter, then run the installer again."
        return 1
    }

    # 7. The per-run questions (C2); non-interactive runs take the defaults.
    if (Read-YesNo -Prompt 'Update vc-build?' -Default $true -NonInteractive $NonInteractive) {
        if (-not (Update-VcBuildTool)) {
            if (Get-Command vc-build -CommandType Application, ExternalScript -ErrorAction Ignore) {
                Write-Warning 'vc-build was not updated; continuing with the installed version.'
            }
            else {
                Write-Warning 'vc-build could not be installed, and the build needs it: dotnet tool install -g VirtoCommerce.GlobalTool'
            }
        }
    }
    if ($mustBuild) {
        Write-Host 'Building: the images of the old start-local cannot run with the new compose files.' -ForegroundColor Yellow
    }
    elseif (-not (Read-YesNo -Prompt 'Build the solution now?' -Default $true -NonInteractive $NonInteractive)) {
        Write-Host 'Build skipped. Run it later with: ./build.ps1' -ForegroundColor Yellow
        return 0
    }

    # 8. build.ps1 gets the per-run switches only.
    # Over an earlier install the database may hold the user's data, and the platform imports sample data into any
    # database that never had it: an update skips it unless asked.
    $skipSampleData = if ($options.Keys -contains 'skipSampleData') { [bool]$options['skipSampleData'] } else { $isUpdate }
    if ($isUpdate -and $options.Keys -notcontains 'skipSampleData') {
        Write-Host 'Skipping sample data: this folder is an existing install. To import it, run the installer with -skipSampleData:$false.' -ForegroundColor Yellow
    }
    [int](Invoke-SolutionBuild -TargetFolder $solutionPath -SkipSampleData $skipSampleData -NonInteractive $NonInteractive)
}
