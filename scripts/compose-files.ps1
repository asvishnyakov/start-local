# The COMPOSE_FILE catalog and its normalization.
#
# COMPOSE_FILE lists the compose files of the stack. Users and switches pick feature files; the scripts
# maintain link files (wiring two features together) and .https.yml overlays (the HTTPS mode), and keep
# the whole list in the canonical order of $script:ComposeFileCatalog.
#
# Catalog entry: [pscustomobject]@{ Name; Kind; Feature; OverlayOf; Requires; Excludes; Generated }
#   Kind      base | mode | provider | feature | overlay | optin | link
#   Feature   switch key of a provider, feature or opt-in file (postgres, platform, esLimited, ...); else $null
#   OverlayOf Name of the file an overlay belongs to; else $null
#   Requires  Names that must be emitted for this file to stay listed (a feature or opt-in without them is
#             dropped with a warning; a link without them is simply not added)
#   Excludes  Names that must not be emitted for a link to be added
#   Generated $true when a script writes the file (it is emitted only on request)
#
# Names are COMPOSE_FILE entries: paths relative to the solution folder, always with '/'. The base file stays in the
# folder itself, so it is the first file Compose reads and the folder stays the project directory; every other file
# lives in the docker-compose/ subfolder.

# The database providers, in the order the installer offers them. Parameter ValidateSet attributes must repeat the
# names literally (an attribute cannot read a variable).
$script:DbProviders = 'postgres', 'mysql', 'sqlserver'

$script:ComposeFolderName = 'docker-compose'

function Get-ComposeFileName {
    # The COMPOSE_FILE entry for a file suffix: 'yml' -> 'docker-compose.yml', 'platform.yml' -> 'docker-compose/platform.yml'.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Suffix
    )

    if ($Suffix -eq 'yml') {
        return 'docker-compose.yml'
    }
    "$script:ComposeFolderName/$Suffix"
}

$script:ComposeFileCatalog = & {
    function New-ComposeCatalogEntry {
        param(
            [string]$Suffix,
            [string]$Kind,
            [string]$Feature,
            [string]$OverlayOf,
            [string[]]$Requires = @(),
            [string[]]$Excludes = @(),
            [bool]$Generated = $false
        )

        [pscustomobject]@{
            Name      = Get-ComposeFileName $Suffix
            Kind      = $Kind
            Feature   = if ($Feature) { $Feature } else { $null }
            OverlayOf = if ($OverlayOf) { Get-ComposeFileName $OverlayOf } else { $null }
            Requires  = [string[]]@($Requires | ForEach-Object { Get-ComposeFileName $_ })
            Excludes  = [string[]]@($Excludes | ForEach-Object { Get-ComposeFileName $_ })
            Generated = $Generated
        }
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    $entries.Add((New-ComposeCatalogEntry 'yml' 'base'))
    $entries.Add((New-ComposeCatalogEntry 'https.yml' 'mode'))
    foreach ($provider in $script:DbProviders) {
        $entries.Add((New-ComposeCatalogEntry "$provider.yml" 'provider' -Feature $provider))
    }
    $entries.Add((New-ComposeCatalogEntry 'platform.yml' 'feature' -Feature 'platform'))
    $entries.Add((New-ComposeCatalogEntry 'platform.https.yml' 'overlay' -OverlayOf 'platform.yml'))
    $entries.Add((New-ComposeCatalogEntry 'elasticsearch.yml' 'feature' -Feature 'elasticsearch'))
    $entries.Add((New-ComposeCatalogEntry 'elasticsearch.https.yml' 'overlay' -OverlayOf 'elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'es-limited.yml' 'optin' -Feature 'esLimited' -Requires 'elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'kibana.yml' 'feature' -Feature 'kibana' -Requires 'elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'kibana.https.yml' 'overlay' -OverlayOf 'kibana.yml'))
    $entries.Add((New-ComposeCatalogEntry 'redis.yml' 'feature' -Feature 'redis'))
    $entries.Add((New-ComposeCatalogEntry 'frontend.yml' 'feature' -Feature 'frontend'))
    $entries.Add((New-ComposeCatalogEntry 'frontend.https.yml' 'overlay' -OverlayOf 'frontend.yml'))
    foreach ($provider in $script:DbProviders) {
        $entries.Add((New-ComposeCatalogEntry "platform-$provider.yml" 'link' -Requires 'platform.yml', "$provider.yml"))
    }
    $entries.Add((New-ComposeCatalogEntry 'platform-elasticsearch.yml' 'link' -Requires 'platform.yml', 'elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'platform-elasticsearch.https.yml' 'overlay' -OverlayOf 'platform-elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'platform-redis.yml' 'link' -Requires 'platform.yml', 'redis.yml'))
    $entries.Add((New-ComposeCatalogEntry 'platform-frontend.yml' 'link' -Requires 'platform.yml', 'frontend.yml'))
    $entries.Add((New-ComposeCatalogEntry 'platform-modules.yml' 'link' -Requires 'platform.yml' -Generated $true))
    $entries.Add((New-ComposeCatalogEntry 'kibana-elasticsearch.yml' 'link' -Requires 'kibana.yml', 'elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'kibana-elasticsearch.https.yml' 'overlay' -OverlayOf 'kibana-elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'frontend-hostplatform.yml' 'link' -Requires 'frontend.yml' -Excludes 'platform.yml'))
    , $entries.ToArray()
}
# A COMPOSE_FILE entry outside this set is the user's own file, which the scripts keep.
$script:ComposeFileCatalogNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@($script:ComposeFileCatalog | ForEach-Object { $_.Name }), [System.StringComparer]::Ordinal)

$script:ComposeHttpsFile = Get-ComposeFileName 'https.yml'
$script:ComposeModulesFile = Get-ComposeFileName 'platform-modules.yml'

# Every published port, in the order the file list gives the services: its .env key, the standard host port
# (FRONTEND_PORT: 443 in HTTPS mode, 80 in HTTP mode), the port inside the container, and the name the service list
# shows. The one place these numbers live.
$script:PortCatalog = @(
    @{ Provider = 'postgres'; Key = 'PGSQL_PORT'; Default = 5432; ContainerPort = 5432 }
    @{ Provider = 'mysql'; Key = 'MYSQL_PORT'; Default = 3306; ContainerPort = 3306 }
    @{ Provider = 'sqlserver'; Key = 'MSSQL_PORT'; Default = 1433; ContainerPort = 1433 }
    @{ File = (Get-ComposeFileName 'platform.yml'); Key = 'PLATFORM_PORT'; Default = 8090; ContainerPort = 8080; Name = 'Platform' }
    @{ File = (Get-ComposeFileName 'elasticsearch.yml'); Key = 'ES_PORT'; Default = 9200; ContainerPort = 9200; Name = 'Elasticsearch' }
    @{ File = (Get-ComposeFileName 'kibana.yml'); Key = 'KIBANA_PORT'; Default = 5601; ContainerPort = 5601; Name = 'Kibana' }
    @{ File = (Get-ComposeFileName 'redis.yml'); Key = 'REDIS_PORT'; Default = 6379; ContainerPort = 6379 }
    @{ File = (Get-ComposeFileName 'frontend.yml'); Key = 'FRONTEND_PORT'; Default = 443; HttpDefault = 80; ContainerPort = 8080; Name = 'Storefront' }
)

function Get-PortEntry {
    # The catalog entry of a port key (PLATFORM_PORT, ...), or of a database provider's port.
    [CmdletBinding(DefaultParameterSetName = 'Key')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Key')][string]$Key,
        [Parameter(Mandatory, ParameterSetName = 'Provider')][string]$Provider
    )

    # The parameter set names the catalog field to match: Key or Provider.
    $field = $PSCmdlet.ParameterSetName
    $value = if ($field -eq 'Key') { $Key } else { $Provider }
    $entry = $script:PortCatalog | Where-Object { $_[$field] -eq $value }
    if (-not $entry) {
        throw [System.ArgumentException]::new("No port is known for '$value'.")
    }
    $entry
}

function Get-PortDefault {
    # The standard host port of a key, as text; FRONTEND_PORT depends on the mode.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [bool]$Https = $true
    )

    $entry = Get-PortEntry -Key $Key
    if (-not $Https -and $entry.HttpDefault) { [string]$entry.HttpDefault } else { [string]$entry.Default }
}

function Get-ComposeFileList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Value,
        [Parameter(Position = 1)][string]$Separator = ';'
    )

    # A hand-written 'docker-compose\postgres.yml' (Windows) is the catalog's 'docker-compose/postgres.yml'.
    # A leading './' names the same file.
    $files = $Value.Split($Separator) | ForEach-Object { $_.Trim().Replace('\', '/') -replace '^(\./)+', '' } | Where-Object { $_ }
    # The unary comma keeps an empty or single-item list an array through the pipeline.
    , [string[]]@($files)
}

function Get-ComposeSeparator {
    # COMPOSE_PATH_SEPARATOR of the document; missing or empty means ';' (an empty value would split nothing).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][psobject]$Document)

    $separator = Get-EnvValue -Document $Document -Key 'COMPOSE_PATH_SEPARATOR'
    if ([string]::IsNullOrEmpty($separator)) { ';' } else { $separator }
}

function Get-EnvComposeFiles {
    # The COMPOSE_FILE list of the document, split by its separator.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][psobject]$Document)

    Get-ComposeFileList (Get-EnvValue -Document $Document -Key 'COMPOSE_FILE' -Default '') (Get-ComposeSeparator $Document)
}

function ConvertTo-ComposeFileValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Position = 1)][string]$Separator = ';'
    )

    $ComposeFiles -join $Separator
}

function Get-ComposeFeatures {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    $isListed = { param($name) $ComposeFiles -ccontains $name }
    [pscustomobject]@{
        Provider      = Resolve-DbProvider -ComposeFiles $ComposeFiles
        Platform      = & $isListed (Get-ComposeFileName 'platform.yml')
        Elasticsearch = & $isListed (Get-ComposeFileName 'elasticsearch.yml')
        Kibana        = & $isListed (Get-ComposeFileName 'kibana.yml')
        Redis         = & $isListed (Get-ComposeFileName 'redis.yml')
        Frontend      = & $isListed (Get-ComposeFileName 'frontend.yml')
        Https         = & $isListed $script:ComposeHttpsFile
    }
}

function Resolve-DbProvider {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    $providers = @($script:ComposeFileCatalog |
            Where-Object { $_.Kind -eq 'provider' -and $ComposeFiles -ccontains $_.Name } |
            ForEach-Object { $_.Feature })
    if ($providers.Count -gt 1) {
        throw [System.InvalidOperationException]::new(
            "COMPOSE_FILE lists more than one database provider: $($providers -join ', '). List exactly one.")
    }
    if ($providers.Count -eq 0) {
        return $null
    }
    $providers[0]
}

function Update-ComposeFileList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][bool]$HasSourceModules
    )

    $listed = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ComposeFiles), [System.StringComparer]::Ordinal)
    $emitted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $result = [System.Collections.Generic.List[string]]::new()
    $httpsMode = $listed.Contains($script:ComposeHttpsFile)

    foreach ($entry in $script:ComposeFileCatalog) {
        $missing = @($entry.Requires | Where-Object { -not $emitted.Contains($_) })
        $emit = switch ($entry.Kind) {
            'base' { $true }
            'mode' { $listed.Contains($entry.Name) }
            { $_ -in 'provider', 'feature', 'optin' } {
                if ($listed.Contains($entry.Name) -and $missing.Count -gt 0) {
                    $switchName = @($script:SkipSwitchFeatures.Keys | Where-Object { $script:SkipSwitchFeatures[$_] -eq $entry.Feature }) | Select-Object -First 1
                    $readd = if ($switchName) { "bring it back with -${switchName}:`$false once they are listed again" } else { 'add it back to COMPOSE_FILE once they are listed again' }
                    Write-Warning "$($entry.Name) needs $($missing -join ', ') in COMPOSE_FILE; dropped it. To keep it, $readd."
                }
                $listed.Contains($entry.Name) -and $missing.Count -eq 0
            }
            'link' {
                $excluded = @($entry.Excludes | Where-Object { $emitted.Contains($_) })
                $missing.Count -eq 0 -and $excluded.Count -eq 0 -and (-not $entry.Generated -or $HasSourceModules)
            }
            'overlay' { $httpsMode -and $emitted.Contains($entry.OverlayOf) }
        }
        if ($emit) {
            $null = $emitted.Add($entry.Name)
            $result.Add($entry.Name)
        }
    }

    foreach ($file in $ComposeFiles) {
        if (-not $script:ComposeFileCatalogNames.Contains($file)) {
            $result.Add($file)
        }
    }

    , $result.ToArray()
}

function Test-ComposeHasSourceModules {
    param([string[]]$ComposeFiles)

    $ComposeFiles -ccontains $script:ComposeModulesFile
}

function Set-ComposeFile {
    # Adds or removes one file, then normalizes. The generated platform-modules file keeps its state.
    param(
        [string[]]$ComposeFiles,
        [string]$Name,
        [bool]$Enabled
    )

    $files = @($ComposeFiles | Where-Object { $_ -cne $Name })
    if ($Enabled) {
        $files += $Name
    }
    Update-ComposeFileList -ComposeFiles $files -HasSourceModules (Test-ComposeHasSourceModules $ComposeFiles)
}

function Set-ComposeFeature {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][ValidateSet('platform', 'elasticsearch', 'kibana', 'redis', 'frontend', 'esLimited')][string]$Feature,
        [Parameter(Mandatory, Position = 2)][bool]$Enabled
    )

    $entry = $script:ComposeFileCatalog |
        Where-Object { $_.Kind -in 'feature', 'optin' -and $_.Feature -eq $Feature } |
        Select-Object -First 1
    Set-ComposeFile -ComposeFiles $ComposeFiles -Name $entry.Name -Enabled $Enabled
}

function Set-ComposeProvider {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][ValidateSet('postgres', 'mysql', 'sqlserver')][string]$Provider
    )

    $providerNames = @($script:ComposeFileCatalog | Where-Object { $_.Kind -eq 'provider' } | ForEach-Object { $_.Name })
    $others = @($ComposeFiles | Where-Object { $providerNames -cnotcontains $_ })
    $name = ($script:ComposeFileCatalog | Where-Object { $_.Kind -eq 'provider' -and $_.Feature -eq $Provider }).Name
    Update-ComposeFileList -ComposeFiles (@($others) + $name) -HasSourceModules (Test-ComposeHasSourceModules $ComposeFiles)
}

function Set-ComposeHttps {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][bool]$Enabled
    )

    Set-ComposeFile -ComposeFiles $ComposeFiles -Name $script:ComposeHttpsFile -Enabled $Enabled
}

function Get-DefaultComposeFiles {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('postgres', 'mysql', 'sqlserver')][string]$Provider,
        [Parameter(Position = 1)][bool]$Https = $true
    )

    $names = [System.Collections.Generic.List[string]]::new()
    $names.Add((Get-ComposeFileName 'yml'))
    if ($Https) {
        $names.Add($script:ComposeHttpsFile)
    }
    $names.Add((Get-ComposeFileName "$Provider.yml"))
    foreach ($feature in 'platform', 'elasticsearch', 'kibana', 'redis', 'frontend') {
        $names.Add((Get-ComposeFileName "$feature.yml"))
    }
    Update-ComposeFileList -ComposeFiles $names.ToArray() -HasSourceModules $false
}

function Get-ComposeProjectName {
    # Compose's default project name for a folder: lowercase, [a-z0-9_-] only, no leading '_' or '-'.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$FolderPath
    )

    $leaf = [System.IO.Path]::GetFileName($FolderPath.TrimEnd('/', '\'))
    $name = ($leaf.ToLowerInvariant() -replace '[^a-z0-9_-]', '').TrimStart('_', '-')
    if (-not $name) {
        throw [System.ArgumentException]::new("No valid Compose project name can be derived from the folder '$FolderPath'.", 'FolderPath')
    }
    $name
}

function Get-SolutionVolumeNames {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Prefix
    )

    # modules-data is no longer mounted; it stays listed so a full remove deletes the one an earlier version created.
    $suffixes = 'postgres_data', 'mysql_data', 'mssql_data', 'cms-content-data', 'modules-data', 'esdata01', 'redisdata', 'certs'
    , [string[]]@($suffixes | ForEach-Object { "${Prefix}_$_" })
}

function Get-SolutionImageNames {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$ProjectName
    )

    , [string[]]@("vc-platform:$ProjectName-latest", "vc-frontend:$ProjectName-latest")
}

function Test-RemovableFolder {
    # $false for a folder with a .git entry (a checkout, or a worktree whose .git is a file): the repository root is
    # itself a valid solution folder, and remove must never delete it (P13).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Folder
    )

    -not (Test-Path -LiteralPath (Join-Path $Folder '.git'))
}

function Get-SolutionProjectName {
    # The Compose project name of a solution folder: COMPOSE_PROJECT_NAME from the .env document, else the
    # folder's default. The document may be $null (no .env yet).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$SolutionFolder
    )

    $projectName = if ($Document) { Get-EnvValue -Document $Document -Key 'COMPOSE_PROJECT_NAME' }
    if ([string]::IsNullOrWhiteSpace($projectName)) {
        $projectName = Get-ComposeProjectName -FolderPath $SolutionFolder
    }
    $projectName
}

function Get-VolumePrefix {
    # The prefix of the solution's named volumes, as the compose files spell it: ${VOLUME_PREFIX:-${COMPOSE_PROJECT_NAME}}.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$SolutionFolder
    )

    $volumePrefix = if ($Document) { Get-EnvValue -Document $Document -Key 'VOLUME_PREFIX' }
    if ([string]::IsNullOrWhiteSpace($volumePrefix)) {
        $volumePrefix = Get-SolutionProjectName -Document $Document -SolutionFolder $SolutionFolder
    }
    $volumePrefix
}

function Get-KeepDataDeletePaths {
    # The paths under <Folder> that `remove -keepData` deletes (F6): everything except .env and the user's own compose
    # files that COMPOSE_FILE names (entries outside the catalog, Update-ComposeFileList keeps them too). A folder that
    # holds a kept file is entered, and only its other children are deleted. A linked folder is never entered, since its
    # children live elsewhere: it stays whole when it holds a kept file, and is otherwise deleted as a link.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Folder,
        [Parameter(Position = 1)][psobject]$Document
    )

    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $folderPath = [System.IO.Path]::GetFullPath($Folder)
    $kept = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::FromComparison($comparison))
    $null = $kept.Add((Join-Path $folderPath '.env'))
    if ($Document) {
        foreach ($entry in (Get-EnvComposeFiles $Document)) {
            if (-not $script:ComposeFileCatalogNames.Contains($entry)) {
                $null = $kept.Add([System.IO.Path]::GetFullPath($entry, $folderPath))
            }
        }
    }
    $collect = {
        param([string]$Directory)
        foreach ($child in Get-ChildItem -LiteralPath $Directory -Force) {
            if ($kept.Contains($child.FullName)) {
                continue
            }
            $prefix = $child.FullName + [System.IO.Path]::DirectorySeparatorChar
            if ($child.PSIsContainer -and @($kept | Where-Object { $_.StartsWith($prefix, $comparison) }).Count -gt 0) {
                if (-not $child.LinkTarget) {
                    & $collect $child.FullName
                }
                continue
            }
            $child.FullName
        }
    }
    , [string[]]@(& $collect $folderPath)
}

function Get-RemovalPlan {
    # What remove.ps1 does to a solution folder: the `docker compose` arguments, the volumes and images to delete
    # by name, and the paths to delete. The names follow the compose files: volumes use VOLUME_PREFIX, else the project
    # name; images use the project name (COMPOSE_PROJECT_NAME, else the folder name).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Folder,
        [Parameter(Mandatory, Position = 1)][bool]$KeepData
    )

    $envPath = Join-Path $Folder '.env'
    $document = if (Test-Path -LiteralPath $envPath -PathType Leaf) { Read-EnvFile -Path $envPath }
    $projectName = Get-SolutionProjectName -Document $document -SolutionFolder $Folder
    $volumePrefix = Get-VolumePrefix -Document $document -SolutionFolder $Folder

    if ($KeepData) {
        $downArgs = [string[]]@('down', '--remove-orphans')
        $volumes = [string[]]@()
        $deletePaths = Get-KeepDataDeletePaths -Folder $Folder -Document $document
    }
    else {
        $downArgs = [string[]]@('down', '-v', '--remove-orphans')
        $volumes = Get-SolutionVolumeNames -Prefix $volumePrefix
        $deletePaths = [string[]]@($Folder)
    }

    [pscustomobject]@{
        DownArgs    = $downArgs
        Volumes     = $volumes
        Images      = Get-SolutionImageNames -ProjectName $projectName
        DeletePaths = $deletePaths
    }
}

function Remove-DockerResource {
    # Removes a Docker volume or image. Returns $null when it is gone (removed now, or absent already: "No such ...");
    # otherwise the reason it is still there, in Docker's words.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('volume', 'image')][string]$Kind,
        [Parameter(Mandatory)][string]$Name
    )

    $output = if ($Kind -eq 'volume') { docker volume rm $Name 2>&1 } else { docker rmi $Name 2>&1 }
    if ($LASTEXITCODE -eq 0) {
        return $null
    }
    $message = ConvertTo-NativeMessage $output "docker exited with code $LASTEXITCODE"
    if ($message -match "no such $Kind") {
        return $null
    }
    $message
}
