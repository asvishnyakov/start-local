# Helpers for the tests. Dot-source after scripts/_init.ps1: . "$PSScriptRoot/../support/TestHelpers.ps1"

function Get-TestRepositoryRoot {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
}

function Get-TestScratchRoot {
    # $TMPDIR on Linux and macOS, %TEMP% on Windows.
    [System.IO.Path]::GetTempPath()
}

function New-ComposeFixtureFolder {
    # A folder named $FolderName with the listed compose files from the repository and a .env made from
    # .env.example: COMPOSE_FILE set, secrets filled, then the overrides. Returns the folder path.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$ComposeFiles,
        [Parameter(Position = 1)][hashtable]$EnvOverrides = @{},
        [Parameter(Position = 2)][string]$FolderName = 'fixture'
    )

    $repositoryRoot = Get-TestRepositoryRoot
    $parent = Join-Path (Get-TestScratchRoot) "sl-fixture-$([guid]::NewGuid().ToString('N'))"
    $folder = Join-Path $parent $FolderName
    $null = New-Item -ItemType Directory -Path $folder -Force

    # A listed file the repository doesn't have yet is left out, so Compose reports it by name.
    foreach ($name in $ComposeFiles) {
        $source = Join-Path $repositoryRoot $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            # The name is a relative path (docker-compose/postgres.yml), so the copy keeps its subfolder.
            $destination = Join-Path $folder $name
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
            Copy-Item -LiteralPath $source -Destination $destination
        }
    }

    $document = Read-EnvFile (Join-Path $repositoryRoot '.env.example')
    $separator = Get-ComposeSeparator $document
    Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value (ConvertTo-ComposeFileValue -ComposeFiles $ComposeFiles -Separator $separator)
    $null = Update-EnvSecrets -Document $document -SecretKeys $script:SecretKeys
    foreach ($key in $EnvOverrides.Keys) {
        Set-EnvValue -Document $document -Key $key -Value ([string]$EnvOverrides[$key])
    }
    Write-EnvFile -Document $document -Path (Join-Path $folder '.env')

    $folder
}

# The keys a platform stack's .env must not hold: the services stack owns them and a key present in the platform .env
# shadows the services value (P2). Spelled out here until Get-ServicesOwnedKeys exists; keep the two lists equal.
$script:SharedFixtureServicesOwnedKeys = @($script:SecretKeys) + @(
    'PGSQL_VERSION', 'PGSQL_PORT', 'MYSQL_VERSION', 'MYSQL_PORT', 'MSSQL_VERSION', 'MSSQL_PORT',
    'STACK_VERSION', 'ES_PORT', 'KIBANA_PORT', 'ES_MEM_LIMIT', 'REDIS_PORT', 'SERVICES_NETWORK_NAME', 'SERVICES_CERTS_VOLUME'
)

function New-SharedStackFixture {
    # Sibling folders services/ and platform/ under one scratch parent, each with the listed compose files copied from the
    # repository and a .env made from .env.example. The services .env has COMPOSE_FILE = $ServicesFiles, STACK_ROLE=services,
    # COMPOSE_PROJECT_NAME=services, the two keys services start writes (P5), secrets filled, then $ServicesEnv. The platform .env
    # has COMPOSE_FILE = '../services/docker-compose.yml' + $PlatformFiles (P1), no services-owned key (P2),
    # COMPOSE_PROJECT_NAME=platform, STACK_ROLE=platform, SERVICES_FOLDER and the S9 keys of project "platform" (P11),
    # then $PlatformEnv: a key set there is present in the file, even when empty.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$ServicesFiles,
        [Parameter(Mandatory, Position = 1)][string[]]$PlatformFiles,
        [Parameter(Position = 2)][hashtable]$PlatformEnv = @{},
        [Parameter(Position = 3)][hashtable]$ServicesEnv = @{}
    )

    $repositoryRoot = Get-TestRepositoryRoot
    $root = Join-Path (Get-TestScratchRoot) "sl-shared-$([guid]::NewGuid().ToString('N'))"
    $servicesFolder = Join-Path $root 'services'
    $platformFolder = Join-Path $root 'platform'

    $copyComposeFiles = {
        param([string]$Folder, [string[]]$Names)

        $null = New-Item -ItemType Directory -Path $Folder -Force
        foreach ($name in $Names) {
            $source = Join-Path $repositoryRoot $name
            # A listed file the repository doesn't have yet is left out, so Compose reports it by name.
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $destination = Join-Path $Folder $name
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
                Copy-Item -LiteralPath $source -Destination $destination
            }
        }
    }
    $writeEnv = {
        param([string]$Folder, [string[]]$Files, [hashtable]$Values, [string[]]$RemovedKeys)

        $document = Read-EnvFile (Join-Path $repositoryRoot '.env.example')
        foreach ($key in $RemovedKeys) {
            $null = Remove-EnvKey -Document $document -Key $key
        }
        Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value (ConvertTo-ComposeFileValue -ComposeFiles $Files -Separator (Get-ComposeSeparator $document))
        foreach ($key in $Values.Keys) {
            Set-EnvValue -Document $document -Key $key -Value ([string]$Values[$key])
        }
        Write-EnvFile -Document $document -Path (Join-Path $Folder '.env')
    }

    & $copyComposeFiles $servicesFolder $ServicesFiles
    $servicesDocument = Read-EnvFile (Join-Path $repositoryRoot '.env.example')
    $null = Update-EnvSecrets -Document $servicesDocument -SecretKeys $script:SecretKeys
    $servicesValues = [ordered]@{
        STACK_ROLE             = 'services'
        COMPOSE_PROJECT_NAME   = 'services'
        SERVICES_NETWORK_NAME  = 'services-shared'
        SERVICES_CERTS_VOLUME  = 'services_certs'
    }
    foreach ($key in $script:SecretKeys) {
        $servicesValues[$key] = Get-EnvValue -Document $servicesDocument -Key $key
    }
    foreach ($key in $ServicesEnv.Keys) {
        $servicesValues[$key] = $ServicesEnv[$key]
    }
    & $writeEnv $servicesFolder $ServicesFiles $servicesValues @()

    & $copyComposeFiles $platformFolder $PlatformFiles
    $platformValues = [ordered]@{
        STACK_ROLE           = 'platform'
        SERVICES_FOLDER      = '../services'
        COMPOSE_PROJECT_NAME = 'platform'
        PLATFORM_HOSTNAME    = 'platform.dev.internal'
        DB_NAME              = 'VirtoCommerce_platform'
        SEARCH_SCOPE         = 'platform'
        REDIS_CHANNEL        = 'VirtoCommerceChannel-platform'
        REDIS_DATABASE       = '0'
    }
    foreach ($key in $PlatformEnv.Keys) {
        $platformValues[$key] = $PlatformEnv[$key]
    }
    & $writeEnv $platformFolder (@('../services/docker-compose.yml') + $PlatformFiles) $platformValues $script:SharedFixtureServicesOwnedKeys

    [pscustomobject]@{ Root = $root; ServicesFolder = $servicesFolder; PlatformFolder = $platformFolder }
}

function Invoke-ComposeConfigJson {
    # `docker compose config --format json` in the folder, parsed. $env:SL_COMPOSE_BINARY, when set, is a
    # standalone Compose binary used instead of the `docker compose` plugin. Throws with Compose's message on failure.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Folder
    )

    $arguments = @('config', '--format', 'json')
    Push-Location -LiteralPath $Folder
    try {
        $output = if ($env:SL_COMPOSE_BINARY) {
            & $env:SL_COMPOSE_BINARY @arguments 2>&1
        }
        else {
            & docker compose @arguments 2>&1
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    $errorText = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw [System.InvalidOperationException]::new("docker compose config failed in '$Folder' (exit $exitCode): $errorText")
    }
    ($output | Select-NativeStdout) -join [Environment]::NewLine | ConvertFrom-Json
}

function New-ScratchSolution {
    # A clean solution folder $TMPDIR/sl-<Name> holding the payload of this repository, for live checks.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][string]$Name = [guid]::NewGuid().ToString('N').Substring(0, 8)
    )

    $folder = Join-Path (Get-TestScratchRoot) "sl-$Name"
    if (Test-Path -LiteralPath $folder) {
        Remove-Item -LiteralPath $folder -Recurse -Force
    }
    Copy-Payload -Root (Get-TestRepositoryRoot) -Destination $folder
    $folder
}

function New-TestSolutionFolder {
    # A solution folder under TestDrive: the payload of this repository, plus a .env made from .env.example with
    # RELEASE_CHANNEL=stable, COMPOSE_FILE from $ComposeFiles, the $Values, and the secrets filled.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string[]]$ComposeFiles = @('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml'),
        [hashtable]$Values = @{}
    )

    $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    Copy-Payload -Root (Get-TestRepositoryRoot) -Destination $folder
    $document = Read-EnvFile (Join-Path $folder '.env.example')
    Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value ($ComposeFiles -join ';')
    Set-EnvValue -Document $document -Key 'RELEASE_CHANNEL' -Value 'stable'
    foreach ($key in $Values.Keys) {
        Set-EnvValue -Document $document -Key $key -Value ([string]$Values[$key])
    }
    $null = Update-EnvSecrets -Document $document -SecretKeys $script:SecretKeys
    Write-EnvFile -Document $document -Path (Join-Path $folder '.env')
    $folder
}

function New-FakeCommand {
    # A fake native command <Folder>/<Name> (a POSIX shell script; Linux and macOS only) that appends one line per call to
    # <Folder>/<Name>.log, its arguments joined by a space, and one to <Folder>/<Name>.argc, how many arguments it got
    # (the log alone can't tell one argument with spaces from several), then runs $Body (shell code; "$*" holds the
    # arguments). Put <Folder> first on PATH to use it. Returns the log path.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Folder,
        [Parameter(Mandatory, Position = 1)][string]$Name,
        [Parameter(Position = 2)][string]$Body = 'exit 0'
    )

    $null = New-Item -ItemType Directory -Path $Folder -Force
    $log = Join-Path $Folder "$Name.log"
    $path = Join-Path $Folder $Name
    $argumentCountLog = [System.IO.Path]::ChangeExtension($log, 'argc')
    Set-Content -LiteralPath $path -Value "#!/bin/sh`necho `"`$*`" >> '$log'`necho `"`$#`" >> '$argumentCountLog'`n$Body"
    & chmod +x $path
    Assert-NativeSuccess "chmod +x $path"
    $log
}

function Get-FakeCommandCalls {
    # The calls a fake command of New-FakeCommand logged, one line of arguments each; nothing when it was never called.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Log)

    if (Test-Path -LiteralPath $Log -PathType Leaf) {
        Get-Content -LiteralPath $Log
    }
}

function Get-FakeCommandArgumentCounts {
    # How many arguments each call of a fake command of New-FakeCommand got, given its log path; nothing when never called.
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory, Position = 0)][string]$Log)

    $argumentCountLog = [System.IO.Path]::ChangeExtension($Log, 'argc')
    if (Test-Path -LiteralPath $argumentCountLog -PathType Leaf) {
        Get-Content -LiteralPath $argumentCountLog | ForEach-Object { [int]$_ }
    }
}

function New-ModuleFolder {
    # A folder under TestDrive. With $ModuleId it holds a module.manifest, as a module's *.Web folder does.
    param([string]$Name, [string]$ModuleId)

    $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $path = Join-Path $folder $Name
    $null = New-Item -ItemType Directory -Path $path -Force
    if ($ModuleId) {
        Set-Content -LiteralPath (Join-Path $path 'module.manifest') -Value "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<module xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`">`n  <id>$ModuleId</id>`n  <version>3.0.0</version>`n</module>"
    }
    $path
}
