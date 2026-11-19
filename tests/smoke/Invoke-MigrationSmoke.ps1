#Requires -Version 7.0
# Migration smoke test (SPEC §12, §9): creates a layout-1 folder with release/1.0's VirtoLocal_create_local_files.ps1,
# builds and starts it, runs this payload's install.ps1 over it, then checks:
#   - .env got VOLUME_PREFIX=virto, and the running database and platform containers mount the old virto_* volumes;
#   - the installer rebuilt the images: vc-platform:<project>-latest exists;
#   - the platform is healthy on http://localhost:<PLATFORM_PORT> (migrated folders stay in HTTP mode);
#   - admin/store no longer signs in (C1 applied ADMIN_PASSWORD) and ADMIN_PASSWORD does.
# Needs release/1.0 to be published (plan F1). The stack is left running: CI runners are discarded, and locally the
# folder's remove.ps1 takes it down.
param (
    # The layout-1 scripts expect the folder to be named VirtoLocal and to sit in the working directory (the old build
    # script starts ./VirtoLocal/start-VC-solution.ps1), so the folder is <WorkFolder>/VirtoLocal.
    [Parameter(Mandatory)][string]$WorkFolder,
    # The ref of the old layout. Also passed to the old installer as -branch, whose default is dev.
    [string]$Branch = 'release/1.0'
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
. (Join-Path $repositoryRoot 'scripts/_init.ps1')
. (Join-Path $PSScriptRoot '_smoke.ps1')

function Get-DockerVolumeNames {
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Pattern)

    $global:LASTEXITCODE = 0
    $names = @(docker volume ls --format '{{.Name}}')
    Assert-NativeSuccess 'docker volume ls'
    , [string[]]@($names | Where-Object { $_ -cmatch $Pattern })
}

function Get-ServiceVolumeNames {
    # The named volumes mounted by the running container(s) of one compose service of the folder.
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$Service
    )

    Push-Location -LiteralPath $Folder
    try {
        $global:LASTEXITCODE = 0
        $containerIds = @(docker compose ps -q $Service)
        if ($LASTEXITCODE -ne 0 -or $containerIds.Count -eq 0) {
            throw [System.InvalidOperationException]::new("No running container for the service $Service in '$Folder' (docker compose ps exited with code $LASTEXITCODE).")
        }
        $names = @(docker inspect --format '{{range .Mounts}}{{.Name}} {{end}}' @containerIds)
        Assert-NativeSuccess 'docker inspect'
        , [string[]]@($names -join ' ' -split '\s+' | Where-Object { $_ })
    }
    finally {
        Pop-Location
    }
}

$work = [System.IO.Path]::GetFullPath($WorkFolder)
Assert-OutsideRepository -Path $work -RepositoryRoot $repositoryRoot -ParameterName 'WorkFolder'
$target = Join-Path $work 'VirtoLocal'
if (Test-Path -LiteralPath $target) {
    throw [System.ArgumentException]::new("'$target' already exists. The migration smoke starts from an empty folder.", 'WorkFolder')
}

# The layout-1 stack uses fixed names (virto_* volumes, vc-*:local-latest images). Never overwrite what is already there.
$existingVolumes = Get-DockerVolumeNames -Pattern '^virto_'
if ($existingVolumes.Count -gt 0) {
    throw [System.InvalidOperationException]::new("Refusing to run: the volumes $($existingVolumes -join ', ') already exist, and the layout-1 stack would use them. Run this on a clean Docker host.")
}
foreach ($image in 'vc-platform:local-latest', 'vc-frontend:local-latest') {
    if (Test-DockerImage -Name $image) {
        throw [System.InvalidOperationException]::new("Refusing to run: the image $image already exists, and the layout-1 build would replace it. Run this on a clean Docker host.")
    }
}

$pullJob = $null
$null = New-Item -ItemType Directory -Path $work -Force
# The old scripts use paths relative to the working directory, and entry scripts never run in the repository root.
Push-Location -LiteralPath $work
try {
    # 1. The layout-1 folder, the way a user created it: release/1.0's installer, PostgreSQL, latest-stable.
    $oldInstaller = Join-Path $work 'VirtoLocal_create_local_files.ps1'
    $oldInstallerUrl = "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$Branch/VirtoLocal_create_local_files.ps1"
    Write-Host "Downloading $oldInstallerUrl" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $oldInstallerUrl -OutFile $oldInstaller

    # The old scripts are interactive and take their answers from stdin. Installer: update vc-build (y), build now (n).
    # The build is a separate call below, because the old build script takes a boolean, which -File cannot pass.
    $global:LASTEXITCODE = 0
    @('y', 'n') | & pwsh -NoProfile -File $oldInstaller -targetFolder VirtoLocal -dbProvider postgres -branch $Branch
    Assert-NativeSuccess "The layout-1 installer ($Branch)"

    # CIR items 1 and 3: the images of the layout-1 stack are pulled in the background while vc-build downloads.
    $pullJob = Start-ImagePull -Folder $target -ComposeArgument '-f', 'docker-compose.yml', '-f', 'docker-compose.postgres.yml'

    # Build and start with latest-stable. The old build script asks once: run the solution now (y).
    $global:LASTEXITCODE = 0
    @('y') | & pwsh -NoProfile -Command '& ./VirtoLocal/build-VC-solution.ps1 -targetFolder VirtoLocal -vcSolutionVersion latest-stable -skipSampleData $true; exit $LASTEXITCODE'
    Assert-NativeSuccess 'The layout-1 build and start'

    $layoutOneEnv = Read-EnvFile -Path (Join-Path $target '.env')
    $platformUrl = "http://localhost:$(Get-EnvValue -Document $layoutOneEnv -Key 'PLATFORM_PORT' -Default '8090')"
    Assert-Smoke (Watch-Url-Up -ApiUrl $platformUrl -TimeoutMinutes 5 -RetrySeconds 10 -WaitSeconds 0) "the layout-1 platform answers on $platformUrl before the migration"
    $volumesBefore = Get-DockerVolumeNames -Pattern '^virto_'
    Assert-Smoke ($volumesBefore.Count -gt 0) "the layout-1 stack created volumes ($($volumesBefore -join ', '))"

    # 2. This payload's installer over the folder. Layout 1 has no release channel, so it is passed, as the old build's latest-stable.
    # A migrated folder is always rebuilt: the layout-1 images do not fit the layout-2 compose files.
    $transcriptPath = Join-Path $work 'install-transcript.log'
    Invoke-SmokeInstall -Target $target -RepositoryRoot $repositoryRoot -TranscriptPath $transcriptPath

    # 3. What the migration promises: the old data is carried over, not replaced by a fresh stack.
    $document = Read-EnvFile -Path (Join-Path $target '.env')
    Assert-Smoke ((Get-EnvValue -Document $document -Key 'VOLUME_PREFIX') -ceq 'virto') '.env has VOLUME_PREFIX=virto'

    # The migrated stack ignores the old data when it creates <project>_postgres_data next to the unused virto_* volumes,
    # so the containers' own mounts are the proof. The layout-1 volumes are virto_postgres_data and virto_modules-data.
    $databaseVolumes = Get-ServiceVolumeNames -Folder $target -Service 'vc-db'
    Assert-Smoke ($databaseVolumes -ccontains 'virto_postgres_data') "the database container mounts virto_postgres_data ($($databaseVolumes -join ', '))"
    $platformVolumes = Get-ServiceVolumeNames -Folder $target -Service 'vc-platform-web'
    Assert-Smoke ($platformVolumes -ccontains 'virto_modules-data') "the platform container mounts virto_modules-data ($($platformVolumes -join ', '))"

    $volumesAfter = Get-DockerVolumeNames -Pattern '^virto_'
    $lostVolumes = @($volumesBefore | Where-Object { $volumesAfter -cnotcontains $_ })
    Assert-Smoke ($lostVolumes.Count -eq 0) "the virto_* volumes are kept ($($volumesAfter -join ', '))"

    $projectName = Get-SolutionProjectName -Document $document -SolutionFolder $target
    $buildMessage = 'Building: the images of the old start-local cannot run with the new compose files.'
    Assert-Smoke ((Get-Content -LiteralPath $transcriptPath -Raw).Contains($buildMessage)) "the installer reported: $buildMessage"
    Assert-Smoke (Test-DockerImage -Name "vc-platform:$projectName-latest") "vc-platform:$projectName-latest exists"

    $platformUrl = "http://localhost:$(Get-EnvValue -Document $document -Key 'PLATFORM_PORT' -Default '8090')"
    Assert-Smoke (Watch-Url-Up -ApiUrl "$platformUrl/health" -TimeoutMinutes 3 -RetrySeconds 10 -WaitSeconds 0) "$platformUrl/health answers 200"

    $adminPassword = [string](Get-EnvValue -Document $document -Key 'ADMIN_PASSWORD')
    Assert-Smoke (-not [string]::IsNullOrEmpty($adminPassword)) 'ADMIN_PASSWORD is set in .env'
    # Only a refused password (400 invalid_grant) proves C1 changed it: Get-AuthToken returns $null for any failure, a 5xx too.
    $seededReply = Invoke-WebRequest -Uri "$platformUrl/connect/token" -Method Post -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ username = 'admin'; password = 'store'; grant_type = 'password' } -SkipCertificateCheck -SkipHttpErrorCheck
    $seededError = if ("$($seededReply.Content)" -match '^\s*\{') { [string]($seededReply.Content | ConvertFrom-Json).error }
    Assert-Smoke ([int]$seededReply.StatusCode -eq 400 -and $seededError -ceq 'invalid_grant') `
        "admin/store no longer signs in: the platform refuses it with 400 invalid_grant (got $([int]$seededReply.StatusCode) '$seededError')"
    $token = Get-AuthToken -AppAuthUrl "$platformUrl/connect/token" -Username 'admin' -Password $adminPassword
    Assert-Smoke (-not [string]::IsNullOrWhiteSpace($token)) 'admin signs in with ADMIN_PASSWORD'

    Write-Host 'Migration smoke passed.' -ForegroundColor Green
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-SmokeDiagnostics -Folder $target
    exit 1
}
finally {
    Wait-ImagePull -Job $pullJob
    Pop-Location
}
exit 0
