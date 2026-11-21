#Requires -Version 7.4
# Starts the solution folder's Docker stack. Configuration lives in .env; the first-class parameters below are saved
# into it (SPEC §8). -solutionFolder and the per-run switches (-installSampleData, -nonInteractive) are not.
param (
    [string]$solutionFolder = $PSScriptRoot,
    [ValidateSet('postgres', 'mysql', 'sqlserver')]
    [string]$dbProvider,
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
    [switch]$nonInteractive
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/scripts/_init.ps1"

$solutionPath = (Resolve-Path -LiteralPath $solutionFolder -ErrorAction Stop).Path
# A relative path typed at a prompt is relative to where the user ran start, not to the solution folder.
$callerDirectory = (Get-Location).ProviderPath
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
    $missingKeys = Request-RequiredEnvKeys -Document $document -NonInteractive $isNonInteractive -BaseDirectory $callerDirectory -ForStart
    if (-not $isNonInteractive -and $missingKeys.Count -gt 0) {
        # A non-interactive run reports its missing keys in the preflight, first and alone: they are the cause.
        Write-ScriptError "set $($missingKeys -join ', ') in $envPath."
        exit 1
    }

    $separator = Get-ComposeSeparator $document
    # The preflight reads the values as the user left them: normalizing an empty COMPOSE_FILE would hide that it is missing.
    $envValues = Get-EnvTable -Document $document
    $listedFiles = Get-EnvComposeFiles $document
    # P16: the source modules' bind mounts live in a generated compose file, written or removed on every run. Only a
    # Docker platform mounts them; a mixed or invalid MODULE_SOURCE_PATHS gives no mounts here and is reported by the preflight.
    # The plan is computed here, but the file changes only together with COMPOSE_FILE below: Compose fails at project load
    # when .env lists a missing file, so a deletion before the preflight could strand a running stack.
    $mountPlan = @()
    if ($listedFiles -ccontains (Get-ComposeFileName 'platform.yml')) {
        $mountPlan = Get-ModuleMountPlan -Classification (Get-ModuleSourceKind -Paths (Split-ModuleSourcePaths ([string]$envValues['MODULE_SOURCE_PATHS'])))
    }
    $composeFiles = Update-ComposeFileList -ComposeFiles $listedFiles -HasSourceModules ($mountPlan.Count -gt 0)

    $projectName = Get-SolutionProjectName -Document $document -SolutionFolder $solutionPath
    Write-Host 'Checking the environment...' -ForegroundColor Yellow
    $preflightErrors = Invoke-Preflight -EnvValues $envValues -ComposeFiles $composeFiles -NonInteractive $isNonInteractive -ProjectName $projectName -WrittenValues (Get-EnvTable -Document $document -AsWritten)
    if ($preflightErrors.Count -gt 0) {
        foreach ($preflightError in $preflightErrors) {
            Write-ScriptError $preflightError
        }
        exit 1
    }
    Write-Host '... environment is ready' -ForegroundColor Green

    Write-ModulesComposeFile -SolutionFolder $solutionPath -MountPlan $mountPlan
    Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value (ConvertTo-ComposeFileValue $composeFiles $separator)
    Write-EnvFile -Document $document -Path $envPath
    $features = Get-ComposeFeatures -ComposeFiles $composeFiles

    $usesDevCertificate = $features.Https
    $certificateChanged = $false
    if ($usesDevCertificate) {
        # Before up: the platform and the storefront read the certificate from the certificates volume.
        Write-Host 'Copying the development certificate into the certificates volume...' -ForegroundColor Yellow
        $certificateChanged = Sync-DevCertificate -SolutionFolder $solutionPath -VolumeName (Get-CertsVolumeName -Document $document -SolutionFolder $solutionPath) -ProjectName $projectName
        Write-Host '... Development certificate ready' -ForegroundColor Green
    }

    # H3-H6: a platform run from source is prepared here and launched after the Docker services are up.
    # The mode: 'docker', 'source' (launched here), or 'skipped' (the user runs it; a source path still gets its
    # settings file and module links prepared, B6).
    $platformMode = Get-PlatformMode -EnvValues $envValues
    $hasSourcePath = -not [string]::IsNullOrWhiteSpace([string]$envValues['PLATFORM_SOURCE_PATH'])
    $sourceLogDir = Get-SourcePlatformLogDir -SolutionFolder $solutionPath
    # On Windows stderr has its own file; a startup crash may be only there.
    $sourceLogFiles = @(Join-Path $sourceLogDir $script:SourcePlatformLogFileName) + @(if ($IsWindows) { Join-Path $sourceLogDir $script:SourcePlatformErrorLogFileName })
    if ($hasSourcePath) {
        Write-Host 'Preparing the platform from source...' -ForegroundColor Yellow
        $platformPath = Resolve-PlatformSourcePath -Value ([string]$envValues['PLATFORM_SOURCE_PATH'])
        $platformKind = Get-PlatformSourceKind -Path $platformPath
        $platformContentRoot = Get-PlatformContentRoot -Path $platformPath -Kind $platformKind
        $settingsFileName = 'VirtoCommerce.Platform.Web.settings.json'

        if ($platformKind -eq 'checkout') {
            $null = Add-GitInfoExclude -CheckoutPath $platformPath -Entry $settingsFileName
        }
        $linkPlan = Get-ModuleLinkPlan -Classification (Get-ModuleSourceKind -Paths (Split-ModuleSourcePaths ([string]$envValues['MODULE_SOURCE_PATHS']))) -ContentRoot $platformContentRoot
        $linkError = Set-ModuleLinks -LinkPlan $linkPlan
        if ($linkError) {
            Write-ScriptError $linkError
            exit 1
        }

        # E11: the setup container of the Elasticsearch HTTPS overlay writes the CA fingerprint the platform trusts.
        $caFingerprint = $null
        if ($features.Https -and $features.Elasticsearch) {
            $caFingerprint = Get-ElasticsearchCaFingerprint
        }
        # The storefront in Docker reaches this platform through host.docker.internal, which native Docker Engine
        # resolves to the bridge address, not loopback: listen there too (only containers and the host reach it).
        $bindAddress = Get-EnvSettingValue -EnvValues $envValues -Key 'BIND_ADDRESS' -Default '127.0.0.1'
        $needsBridge = $composeFiles -ccontains (Get-ComposeFileName 'frontend-hostplatform.yml') -and -not (Test-WildcardBindAddress $bindAddress)
        $bridgeAddress = if ($needsBridge) { Get-DockerBridgeBindAddress }
        $platformSettings = Get-PlatformSettings -EnvValues (Get-EnvTable -Document $document) -ComposeFiles $composeFiles -Topology Host -CaFingerprint $caFingerprint -BridgeAddress $bridgeAddress
        $settingsPath = Get-SettingsFilePath -PlatformPath $platformPath -Kind $platformKind
        Write-PlatformSettingsFile -Path $settingsPath -Flat $platformSettings
        Write-Host "... Settings written to $settingsPath" -ForegroundColor Green

        # H5: the machine's user secrets override the settings file.
        $secretsPath = Get-PlatformUserSecretsPath
        if (Test-Path -LiteralPath $secretsPath -PathType Leaf) {
            try {
                $shadowedKeys = Get-ShadowedKeys -SecretsJson (Get-Content -LiteralPath $secretsPath -Raw) -SettingKeys ([string[]]@($platformSettings.Keys))
            }
            catch [System.FormatException] {
                Write-Warning "The platform may fail to start on the user secrets in ${secretsPath}: $($_.Exception.Message)"
                $shadowedKeys = @()
            }
            if ($shadowedKeys.Count -gt 0) {
                Write-Warning "The user secrets in $secretsPath override these settings of the platform: $($shadowedKeys -join ', '). Remove them from the secrets (dotnet user-secrets remove), or the platform ignores the values from .env."
            }
        }
    }

    Write-Host 'Starting VC solution...' -ForegroundColor Yellow
    Invoke-DockerCompose up -d --remove-orphans
    if ($LASTEXITCODE -ne 0) {
        Write-ScriptError "docker compose up failed with exit code $LASTEXITCODE."
        exit 1
    }
    # up -d leaves a running container alone when only a file in its volume changed: restart the ones that serve the
    # development certificate, so they load the new one.
    $certificateServices = @(if ($certificateChanged -and $features.Platform) { 'vc-platform-web' }) + @(if ($certificateChanged -and $features.Frontend) { 'vc-frontend' })
    if ($certificateServices.Count -gt 0) {
        Write-Host 'Restarting the services that serve the renewed development certificate...' -ForegroundColor Yellow
        Invoke-DockerCompose restart @certificateServices
        if ($LASTEXITCODE -ne 0) {
            Write-ScriptError "docker compose restart failed with exit code $LASTEXITCODE."
            exit 1
        }
    }
    Write-Host '... VC solution started' -ForegroundColor Green

    $sourceCommand = $null
    if ($hasSourcePath) {
        $sourceCommand = Get-SourcePlatformCommand -Path $platformPath -Kind $platformKind
    }
    if ($platformMode -eq 'source') {
        Write-Host 'Starting the platform from source...' -ForegroundColor Yellow
        # A platform of an earlier run holds the port and runs with the old settings: restart it.
        if (Stop-SourcePlatform -LogDir $sourceLogDir) {
            Write-Host 'Stopped the platform of the earlier run.' -ForegroundColor Yellow
        }
        $platformProcessId = Start-SourcePlatform -Command $sourceCommand -LogDir $sourceLogDir
        Write-Host "... Platform started (pid $platformProcessId, log: $($sourceLogFiles -join ', '))" -ForegroundColor Green
    }

    $serviceUrls = Get-ServiceUrls -EnvValues (Get-EnvTable -Document $document) -ComposeFiles $composeFiles
    $platformUrl = ($serviceUrls | Where-Object { $_.Name -eq 'Platform' }).Url
    $platformReady = $false
    # What went wrong after up. The services keep running either way; a non-interactive run exits 1 on any of them, so an
    # unattended caller (CI, a cloud routine, a wrapper) does not go on with a stand that is not what it asked for.
    $failures = [System.Collections.Generic.List[string]]::new()
    if ($platformMode -ne 'skipped') {
        $platformLogTail = if ($platformMode -eq 'source') {
            { foreach ($logFile in $sourceLogFiles) { Get-Content -LiteralPath $logFile -Tail 50 -ErrorAction Ignore } }
        }
        else {
            { docker compose logs --tail 50 vc-platform-web }
        }
        $platformReady = Watch-Url-Up -ApiUrl $platformUrl -TimeoutMinutes 15 -RetrySeconds 15 -WaitSeconds 15 -OnFailureLog $platformLogTail
        if (-not $platformReady) {
            Write-Warning "The platform at $platformUrl did not become ready, so the modules check, the sample data and the admin password are skipped. The services keep running; see the platform log."
            $failures.Add('the platform did not become ready')
        }
    }
    if ($platformReady) {
        $adminPassword = [string](Get-EnvValue -Document $document -Key 'ADMIN_PASSWORD')

        # One sign-in per run, and its token serves every step below: Identity locks admin for 15 minutes after 5 failed
        # sign-ins, and each refused candidate counts. Nothing below works without it, so a refused sign-in stops the run.
        $adminToken = Get-AdminToken -ApiUrl $platformUrl -AdminPassword $adminPassword
        if ([string]::IsNullOrWhiteSpace($adminToken)) {
            Write-ScriptError "The platform at $platformUrl accepts none of the admin passwords (ADMIN_PASSWORD from .env, then the seeded one), so the modules check, the sample data and the admin password are skipped. The services keep running. After 5 failed sign-ins in a row the platform keeps admin locked for 15 minutes, the right password included: wait, then run start again. If ADMIN_PASSWORD was changed in .env after the first start, change it in the platform first."
            exit 1
        }

        Write-Host 'Checking installed modules...' -ForegroundColor Yellow
        $modulesCheckArguments = @{ ApiUrl = $platformUrl; Token = $adminToken }
        $moduleClassification = Get-ModuleSourceKind -Paths (Split-ModuleSourcePaths ([string]$envValues['MODULE_SOURCE_PATHS']))
        $expectedModuleIds = Get-ExpectedModuleIds -SolutionFolder $solutionPath -PlatformMode $platformMode -Classification $moduleClassification -ContentRoot $platformContentRoot
        if ($null -ne $expectedModuleIds) {
            $modulesCheckArguments['ExpectedModuleIds'] = $expectedModuleIds
        }
        else {
            Write-Host "No list of the modules built into the platform image (backend/$script:ImageModulesFileName), so they are not compared with the installed ones. To have them compared, run ./build.ps1." -ForegroundColor Yellow
        }
        $global:LASTEXITCODE = 0
        & (Join-Path $PSScriptRoot 'scripts/check-installed-modules.ps1') @modulesCheckArguments
        if ($LASTEXITCODE -ne 0) {
            # The sample data runs through the modules' importers: with a failed module it would import partway, and the
            # platform marks it imported anyway, so no later run would retry it.
            Write-ScriptError 'The installed modules check failed, so the sample data and the admin password are skipped. The services keep running; see the errors above.'
            exit 1
        }
        Write-Host '... Installed modules checked' -ForegroundColor Green

        if ($installSampleData) {
            Write-Host 'Setting up sampledata...' -ForegroundColor Yellow
            $global:LASTEXITCODE = 0
            & (Join-Path $PSScriptRoot 'scripts/setup-sampledata.ps1') -ApiUrl $platformUrl -Token $adminToken
            if ($LASTEXITCODE -ne 0) {
                Write-Warning 'Sample data setup failed; the solution is running anyway.'
                $failures.Add('the sample data setup failed')
            }
            else {
                Write-Host '... Sampledata set up' -ForegroundColor Green
            }
        }

        if ($isNonInteractive) {
            # C1: a non-interactive run owns the admin password. After the sample data: its Users section updates admin
            # with the seeded password hash, and the token of the sign-in above still applies the password.
            $generated = [string]::IsNullOrEmpty($adminPassword)
            if ($generated) {
                $adminPassword = New-RandomPassword
                Set-EnvValue -Document $document -Key 'ADMIN_PASSWORD' -Value $adminPassword
                Write-EnvFile -Document $document -Path $envPath
                Write-Host 'Generated ADMIN_PASSWORD and saved it in .env.' -ForegroundColor Yellow
            }
            $applied = $false
            if (Set-AdminPassword -ApiUrl $platformUrl -Token $adminToken -NewPassword $adminPassword) {
                Write-Host 'Admin password applied from ADMIN_PASSWORD.' -ForegroundColor Green
                $applied = $true
            }
            if (-not $applied) {
                $failures.Add('ADMIN_PASSWORD was not applied')
            }
            if ($generated -and -not $applied) {
                Write-Warning 'The ADMIN_PASSWORD just saved in .env is not the platform''s admin password yet; the next start applies it.'
            }
        }
    }

    # es-setup's give-up leaves it healthy, so up succeeds; only its own record tells. The record may still be pending
    # here when no platform was waited for, so the check gives it a minute first.
    $kibanaWarning = Get-KibanaPasswordWarning -ComposeFiles $composeFiles
    if ($kibanaWarning) {
        Write-Warning $kibanaWarning
        if ($kibanaWarning -ceq $script:KibanaPasswordFailedWarning) {
            $failures.Add('Kibana cannot sign in to Elasticsearch')
        }
    }

    Write-Host ''
    Write-Host 'Services:' -ForegroundColor Cyan
    foreach ($service in $serviceUrls) {
        if ($platformMode -eq 'skipped' -and $service.Name -eq 'Platform') {
            # B6: a skipped platform gets its own note below instead of a URL that nothing answers yet.
            continue
        }
        Write-Host ('  {0,-14} {1}' -f $service.Name, $service.Url)
    }
    if ($platformMode -eq 'skipped') {
        Write-Host ''
        if ($sourceCommand) {
            $commandText = ConvertTo-CommandLine (@($sourceCommand.FilePath) + $sourceCommand.Arguments)
            Write-Host "The platform is skipped (SKIP_PLATFORM=true). It will listen on $platformUrl. Launch it yourself, or from your IDE:" -ForegroundColor Yellow
            Write-Host "  working directory: $($sourceCommand.WorkingDirectory)"
            Write-Host '  environment:       ASPNETCORE_ENVIRONMENT=Development'
            Write-Host "  command:           $commandText"
        }
        else {
            Write-Host "The platform is skipped (SKIP_PLATFORM=true). Run it yourself, or from your IDE, so that it listens on $platformUrl." -ForegroundColor Yellow
        }
    }
    if ($usesDevCertificate -and -not (Test-DevCertificateTrusted)) {
        Write-Host ''
        Write-Host (Get-TrustInstructions) -ForegroundColor Yellow
        if ($features.Elasticsearch) {
            Write-Host 'Elasticsearch uses its own setup CA. To trust it the same way, copy it out of the setup container first:' -ForegroundColor Yellow
            Write-Host '     docker compose cp es-setup:/usr/share/elasticsearch/config/certs/ca/ca.crt ./ca.crt' -ForegroundColor Yellow
        }
    }
    if ($isNonInteractive -and $failures.Count -gt 0) {
        Write-Host ''
        Write-ScriptError "The non-interactive run failed: $($failures -join '; '). The services keep running; see the warnings above."
        exit 1
    }
    $global:LASTEXITCODE = 0
}
catch {
    Write-ScriptError -ErrorRecord $_
    exit 1
}
finally {
    Pop-Location
}
