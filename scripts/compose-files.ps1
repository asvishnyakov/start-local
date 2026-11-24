# The COMPOSE_FILE catalog and its normalization.
#
# COMPOSE_FILE lists the compose files of the stack. Users and switches pick feature files; the scripts
# maintain link files (wiring two features together) and .https.yml overlays (the HTTPS mode), and keep
# the whole list in the canonical order of $script:ComposeFileCatalog.
#
# Catalog entry: [pscustomobject]@{ Name; Kind; Feature; OverlayOf; Requires; Excludes; Generated; Roles; MinComposeVersion }
#   Kind      base | mode | provider | feature | overlay | optin | link | role | shared
#             role    the Docker network of a stack role (services-network, shared-network): emitted whenever the role has it
#             shared  a marker of a platform stack (shared-<provider|elasticsearch|redis>): it declares nothing, says which
#                     servers of the services stack the platform stack uses, and drives feature inference (P4)
#   Feature   switch key of a provider, feature, opt-in or shared marker (postgres, platform, esLimited, ...); else $null
#   OverlayOf Name of the file an overlay belongs to; else $null
#   Requires  Names that must be emitted for this file to stay listed (a feature, opt-in or marker without them is
#             dropped with a warning; a link without them is simply not added)
#   Excludes  Names that must not be emitted for a link to be added
#   Generated $true when a script writes the file (it is emitted only on request)
#   Roles     the STACK_ROLEs the file may be emitted in: '' is a standalone stack, then 'services' and 'platform' (S1).
#             Update-ComposeFileList drops a listed entry outside its roles, of any kind, with a warning naming STACK_ROLE.
#   MinComposeVersion  the oldest Docker Compose that accepts the file (P19); else $null
#
# Names are COMPOSE_FILE entries: paths relative to the solution folder, always with '/'. The base file stays in the
# folder itself, so it is the first file Compose reads and the folder stays the project directory; every other file
# lives in the docker-compose/ subfolder. A platform stack's list starts with the services folder's docker-compose.yml, the
# services anchor (P1): it is no catalog file, and Update-ComposeFileList emits it first.

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
            [bool]$Generated = $false,
            [Parameter(Mandatory)][AllowEmptyString()][string[]]$Roles,
            [string]$MinComposeVersion
        )

        [pscustomobject]@{
            Name              = Get-ComposeFileName $Suffix
            Kind              = $Kind
            Feature           = if ($Feature) { $Feature } else { $null }
            OverlayOf         = if ($OverlayOf) { Get-ComposeFileName $OverlayOf } else { $null }
            Requires          = [string[]]@($Requires | ForEach-Object { Get-ComposeFileName $_ })
            Excludes          = [string[]]@($Excludes | ForEach-Object { Get-ComposeFileName $_ })
            Generated         = $Generated
            Roles             = [string[]]@($Roles)
            MinComposeVersion = if ($MinComposeVersion) { $MinComposeVersion } else { $null }
        }
    }

    # '' is the standalone role. The servers are in a standalone stack and in a services stack; the platform and the
    # storefront are in a standalone stack and in a platform stack.
    $everyRole = @('', 'services', 'platform')
    $serverRoles = @('', 'services')
    $platformRoles = @('', 'platform')
    $standalone = @('')
    $services = @('services')
    $platform = @('platform')

    $entries = [System.Collections.Generic.List[object]]::new()
    $entries.Add((New-ComposeCatalogEntry 'yml' 'base' -Roles $everyRole))
    $entries.Add((New-ComposeCatalogEntry 'https.yml' 'mode' -Roles $everyRole))
    $entries.Add((New-ComposeCatalogEntry 'services-network.yml' 'role' -Roles $services))
    $entries.Add((New-ComposeCatalogEntry 'shared-network.yml' 'role' -Roles $platform))
    foreach ($provider in $script:DbProviders) {
        $entries.Add((New-ComposeCatalogEntry "$provider.yml" 'provider' -Feature $provider -Roles $serverRoles))
    }
    foreach ($provider in $script:DbProviders) {
        $entries.Add((New-ComposeCatalogEntry "shared-$provider.yml" 'shared' -Feature $provider -Requires 'shared-network.yml' -Roles $platform))
    }
    $entries.Add((New-ComposeCatalogEntry 'platform.yml' 'feature' -Feature 'platform' -Roles $platformRoles))
    $entries.Add((New-ComposeCatalogEntry 'platform.https.yml' 'overlay' -OverlayOf 'platform.yml' -Roles $platformRoles))
    $entries.Add((New-ComposeCatalogEntry 'elasticsearch.yml' 'feature' -Feature 'elasticsearch' -Roles $serverRoles))
    $entries.Add((New-ComposeCatalogEntry 'elasticsearch.https.yml' 'overlay' -OverlayOf 'elasticsearch.yml' -Roles $serverRoles))
    $entries.Add((New-ComposeCatalogEntry 'shared-elasticsearch.yml' 'shared' -Feature 'elasticsearch' -Requires 'shared-network.yml' -Roles $platform))
    $entries.Add((New-ComposeCatalogEntry 'es-limited.yml' 'optin' -Feature 'esLimited' -Requires 'elasticsearch.yml' -Roles $serverRoles))
    $entries.Add((New-ComposeCatalogEntry 'kibana.yml' 'feature' -Feature 'kibana' -Requires 'elasticsearch.yml' -Roles $serverRoles))
    $entries.Add((New-ComposeCatalogEntry 'kibana.https.yml' 'overlay' -OverlayOf 'kibana.yml' -Roles $serverRoles))
    $entries.Add((New-ComposeCatalogEntry 'redis.yml' 'feature' -Feature 'redis' -Roles $serverRoles))
    $entries.Add((New-ComposeCatalogEntry 'shared-redis.yml' 'shared' -Feature 'redis' -Requires 'shared-network.yml' -Roles $platform))
    $entries.Add((New-ComposeCatalogEntry 'frontend.yml' 'feature' -Feature 'frontend' -Roles $platformRoles))
    $entries.Add((New-ComposeCatalogEntry 'frontend.https.yml' 'overlay' -OverlayOf 'frontend.yml' -Roles $platformRoles))
    foreach ($provider in $script:DbProviders) {
        $entries.Add((New-ComposeCatalogEntry "platform-$provider.yml" 'link' -Requires 'platform.yml', "$provider.yml" -Roles $standalone))
    }
    $entries.Add((New-ComposeCatalogEntry 'platform-elasticsearch.yml' 'link' -Requires 'platform.yml', 'elasticsearch.yml' -Roles $standalone))
    $entries.Add((New-ComposeCatalogEntry 'platform-elasticsearch.https.yml' 'overlay' -OverlayOf 'platform-elasticsearch.yml' -Roles $standalone))
    $entries.Add((New-ComposeCatalogEntry 'platform-redis.yml' 'link' -Requires 'platform.yml', 'redis.yml' -Roles $standalone))
    # A services stack's servers join the shared network (S2). The database link needs only the network: a services
    # stack lists exactly one provider, and the link is the same for every provider.
    $entries.Add((New-ComposeCatalogEntry 'services-database.yml' 'link' -Requires 'services-network.yml' -Roles $services))
    $entries.Add((New-ComposeCatalogEntry 'services-elasticsearch.yml' 'link' -Requires 'services-network.yml', 'elasticsearch.yml' -Roles $services))
    $entries.Add((New-ComposeCatalogEntry 'services-redis.yml' 'link' -Requires 'services-network.yml', 'redis.yml' -Roles $services))
    # A platform stack's wiring to the services stack (P4): the links need platform.yml, the markers say which servers.
    $entries.Add((New-ComposeCatalogEntry 'shared-certs.yml' 'link' -Requires 'https.yml', 'shared-network.yml' -Roles $platform))
    $entries.Add((New-ComposeCatalogEntry 'platform-shared.yml' 'link' -Requires 'platform.yml', 'shared-network.yml' -Roles $platform))
    $entries.Add((New-ComposeCatalogEntry 'platform-shared.https.yml' 'overlay' -OverlayOf 'platform-shared.yml' -Roles $platform))
    $entries.Add((New-ComposeCatalogEntry 'platform-shared-alias.yml' 'link' -Requires 'platform-shared.yml' -Roles $platform -MinComposeVersion '5.7.0'))
    foreach ($provider in $script:DbProviders) {
        $entries.Add((New-ComposeCatalogEntry "platform-shared-$provider.yml" 'link' -Requires 'platform.yml', "shared-$provider.yml" -Roles $platform))
    }
    $entries.Add((New-ComposeCatalogEntry 'platform-shared-elasticsearch.yml' 'link' -Requires 'platform.yml', 'shared-elasticsearch.yml' -Roles $platform))
    $entries.Add((New-ComposeCatalogEntry 'platform-shared-elasticsearch.https.yml' 'overlay' -OverlayOf 'platform-shared-elasticsearch.yml' -Roles $platform))
    $entries.Add((New-ComposeCatalogEntry 'platform-shared-redis.yml' 'link' -Requires 'platform.yml', 'shared-redis.yml' -Roles $platform))
    $entries.Add((New-ComposeCatalogEntry 'platform-frontend.yml' 'link' -Requires 'platform.yml', 'frontend.yml' -Roles $platformRoles))
    $entries.Add((New-ComposeCatalogEntry 'platform-modules.yml' 'link' -Requires 'platform.yml' -Generated $true -Roles $platformRoles))
    $entries.Add((New-ComposeCatalogEntry 'platform-peers.yml' 'link' -Requires 'platform.yml' -Generated $true -Roles $platform))
    $entries.Add((New-ComposeCatalogEntry 'platform-extra-ca.yml' 'link' -Requires 'platform.yml' -Generated $true -Roles $platform))
    $entries.Add((New-ComposeCatalogEntry 'kibana-elasticsearch.yml' 'link' -Requires 'kibana.yml', 'elasticsearch.yml' -Roles $serverRoles))
    $entries.Add((New-ComposeCatalogEntry 'kibana-elasticsearch.https.yml' 'overlay' -OverlayOf 'kibana-elasticsearch.yml' -Roles $serverRoles))
    $entries.Add((New-ComposeCatalogEntry 'frontend-hostplatform.yml' 'link' -Requires 'frontend.yml' -Excludes 'platform.yml' -Roles $platformRoles))
    , $entries.ToArray()
}
# A COMPOSE_FILE entry outside this set is the user's own file, which the scripts keep.
$script:ComposeFileCatalogNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@($script:ComposeFileCatalog | ForEach-Object { $_.Name }), [System.StringComparer]::Ordinal)

$script:ComposeHttpsFile = Get-ComposeFileName 'https.yml'
$script:ComposeModulesFile = Get-ComposeFileName 'platform-modules.yml'

# Every published port, in the order the file list gives the services: its .env key, the standard host port
# (FRONTEND_PORT: 443 in HTTPS mode, 80 in HTTP mode), the port inside the container, and the name the service list
# shows. The one place these numbers live. The platform's ContainerPort is $null: it listens on PLATFORM_PORT inside the
# container too (S7), so a caller that needs it reads the key's value.
$script:PortCatalog = @(
    @{ Provider = 'postgres'; Key = 'PGSQL_PORT'; Default = 5432; ContainerPort = 5432 }
    @{ Provider = 'mysql'; Key = 'MYSQL_PORT'; Default = 3306; ContainerPort = 3306 }
    @{ Provider = 'sqlserver'; Key = 'MSSQL_PORT'; Default = 1433; ContainerPort = 1433 }
    @{ File = (Get-ComposeFileName 'platform.yml'); Key = 'PLATFORM_PORT'; Default = 8090; ContainerPort = $null; Name = 'Platform' }
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
    # What a list uses. Elasticsearch and Redis are true for the server files and for the markers of a platform stack
    # (shared-elasticsearch, shared-redis); Shared and Services say which network file the list has.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    $isListed = { param($name) $ComposeFiles -ccontains (Get-ComposeFileName $name) }
    [pscustomobject]@{
        Provider      = Resolve-DbProvider -ComposeFiles $ComposeFiles
        Platform      = & $isListed 'platform.yml'
        Elasticsearch = (& $isListed 'elasticsearch.yml') -or (& $isListed 'shared-elasticsearch.yml')
        Kibana        = & $isListed 'kibana.yml'
        Redis         = (& $isListed 'redis.yml') -or (& $isListed 'shared-redis.yml')
        Frontend      = & $isListed 'frontend.yml'
        Https         = & $isListed 'https.yml'
        Shared        = & $isListed 'shared-network.yml'
        Services      = & $isListed 'services-network.yml'
    }
}

function Resolve-DbProvider {
    # The database provider a list names, by its provider file or, in a platform stack, by its shared marker.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    $providers = @($script:ComposeFileCatalog |
            Where-Object { $_.Kind -in 'provider', 'shared' -and $_.Feature -in $script:DbProviders -and $ComposeFiles -ccontains $_.Name } |
            ForEach-Object { $_.Feature } |
            Select-Object -Unique)
    if ($providers.Count -gt 1) {
        throw [System.InvalidOperationException]::new(
            "COMPOSE_FILE lists more than one database provider: $($providers -join ', '). List exactly one.")
    }
    if ($providers.Count -eq 0) {
        return $null
    }
    $providers[0]
}

function Get-ListedServicesAnchor {
    # The services anchor (P1) that heads a platform stack's list: its first entry, when that is no catalog file and
    # names a docker-compose.yml. '' when the list has none.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    if ($ComposeFiles.Count -gt 0 -and -not $script:ComposeFileCatalogNames.Contains($ComposeFiles[0]) -and $ComposeFiles[0] -cmatch '/docker-compose\.yml$') {
        return $ComposeFiles[0]
    }
    ''
}

function Get-ListedGeneratedFiles {
    # The generated files (platform-modules, platform-peers, ...) a list holds: the state a re-normalization keeps.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    , [string[]]@($script:ComposeFileCatalog | Where-Object { $_.Generated -and $ComposeFiles -ccontains $_.Name } | ForEach-Object { $_.Name })
}

function Update-ComposeFileList {
    # Normalizes a list into the canonical order of the catalog, for the files the role may have (see Roles above).
    #   -Role            '' (standalone), 'services' or 'platform'.
    #   -ServicesAnchor  A platform stack's first entry (P1): emitted first, never listed again as a user file.
    #   -GeneratedFiles  The generated files to emit (platform-modules also when -HasSourceModules).
    #   -ComposeVersion  The Docker Compose version, for a file that needs one (P19): a file with a MinComposeVersion is
    #                    emitted when the version reaches it and its requirements hold, and dropped, with no warning, when
    #                    the version is lower. An empty version is an unknown one: the file stays when listed and is never added.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][bool]$HasSourceModules,
        [ValidateSet('', 'services', 'platform', IgnoreCase = $false)][AllowEmptyString()][string]$Role = '',
        [string]$ServicesAnchor = '',
        [string[]]$GeneratedFiles = @(),
        [string]$ComposeVersion = ''
    )

    $listed = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ComposeFiles), [System.StringComparer]::Ordinal)
    $emitted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $generated = [System.Collections.Generic.HashSet[string]]::new([string[]]@($GeneratedFiles), [System.StringComparer]::Ordinal)
    if ($HasSourceModules) {
        $null = $generated.Add($script:ComposeModulesFile)
    }
    $result = [System.Collections.Generic.List[string]]::new()
    $httpsMode = $listed.Contains($script:ComposeHttpsFile)
    $roleText = if ($Role) { "STACK_ROLE is $Role" } else { 'STACK_ROLE is empty' }

    if ($ServicesAnchor) {
        $result.Add($ServicesAnchor)
    }
    foreach ($entry in $script:ComposeFileCatalog) {
        if ($entry.Roles -cnotcontains $Role) {
            if ($listed.Contains($entry.Name)) {
                Write-Warning "$($entry.Name) is not used when $roleText; dropped it."
            }
            continue
        }
        $missing = @($entry.Requires | Where-Object { -not $emitted.Contains($_) })
        $emit = switch ($entry.Kind) {
            'base' { $true }
            'mode' { $listed.Contains($entry.Name) }
            'role' { $true }
            { $_ -in 'provider', 'feature', 'optin', 'shared' } {
                if ($listed.Contains($entry.Name) -and $missing.Count -gt 0) {
                    $switchName = @($script:SkipSwitchFeatures.Keys | Where-Object { $script:SkipSwitchFeatures[$_] -eq $entry.Feature }) | Select-Object -First 1
                    $readd = if ($switchName) { "bring it back with -${switchName}:`$false once they are listed again" } else { 'add it back to COMPOSE_FILE once they are listed again' }
                    Write-Warning "$($entry.Name) needs $($missing -join ', ') in COMPOSE_FILE; dropped it. To keep it, $readd."
                }
                $listed.Contains($entry.Name) -and $missing.Count -eq 0
            }
            'link' {
                $excluded = @($entry.Excludes | Where-Object { $emitted.Contains($_) })
                $requested = -not $entry.Generated -or $generated.Contains($entry.Name)
                $supported = $true
                if ($entry.MinComposeVersion) {
                    $supported = if ($ComposeVersion) { Test-ComposeVersion $ComposeVersion $entry.MinComposeVersion } else { $listed.Contains($entry.Name) }
                }
                $missing.Count -eq 0 -and $excluded.Count -eq 0 -and $requested -and $supported
            }
            'overlay' { $httpsMode -and $emitted.Contains($entry.OverlayOf) }
        }
        if ($emit) {
            $null = $emitted.Add($entry.Name)
            $result.Add($entry.Name)
        }
    }

    foreach ($file in $ComposeFiles) {
        if (-not $script:ComposeFileCatalogNames.Contains($file) -and $file -cne $ServicesAnchor) {
            $result.Add($file)
        }
    }

    , $result.ToArray()
}

function Test-ComposeHasSourceModules {
    param([string[]]$ComposeFiles)

    $ComposeFiles -ccontains $script:ComposeModulesFile
}

function Update-ComposeFileListKeepingState {
    # Normalizes $ComposeFiles for the role, carrying over what the list holds besides the user's files: the services anchor
    # of a platform stack, the generated files, and the source-modules link. A listed alias file stays too, since
    # no -ComposeVersion is passed (an unknown version leaves it as listed, P19).
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$Previous,
        [AllowEmptyString()][string]$Role = ''
    )

    $anchor = if ($Role -ceq 'platform') { Get-ListedServicesAnchor $Previous } else { '' }
    Update-ComposeFileList -ComposeFiles $ComposeFiles -HasSourceModules (Test-ComposeHasSourceModules $Previous) `
        -Role $Role -ServicesAnchor $anchor -GeneratedFiles (Get-ListedGeneratedFiles $Previous)
}

function Set-ComposeFile {
    # Adds or removes one file, then normalizes. The generated files, and a platform stack's services anchor, keep their state.
    param(
        [string[]]$ComposeFiles,
        [string]$Name,
        [bool]$Enabled,
        [string]$Role = ''
    )

    $files = @($ComposeFiles | Where-Object { $_ -cne $Name })
    if ($Enabled) {
        $files += $Name
    }
    Update-ComposeFileListKeepingState -ComposeFiles $files -Previous $ComposeFiles -Role $Role
}

function Set-ComposeFeature {
    # Switches a feature on or off. In a platform stack, elasticsearch and redis are the shared markers (S17). A feature the
    # role has no file for cannot be switched on; switching it off leaves the list as it is.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][ValidateSet('platform', 'elasticsearch', 'kibana', 'redis', 'frontend', 'esLimited')][string]$Feature,
        [Parameter(Mandatory, Position = 2)][bool]$Enabled,
        [ValidateSet('', 'services', 'platform', IgnoreCase = $false)][AllowEmptyString()][string]$Role = ''
    )

    $entry = $script:ComposeFileCatalog |
        Where-Object { $_.Kind -in 'feature', 'optin', 'shared' -and $_.Feature -eq $Feature -and $_.Roles -ccontains $Role } |
        Select-Object -First 1
    if (-not $entry) {
        if ($Enabled) {
            $roleText = if ($Role) { "a $Role" } else { 'a standalone' }
            throw [System.ArgumentException]::new("The feature '$Feature' has no compose file in $roleText stack.", 'Feature')
        }
        return , (Update-ComposeFileListKeepingState -ComposeFiles $ComposeFiles -Previous $ComposeFiles -Role $Role)
    }
    Set-ComposeFile -ComposeFiles $ComposeFiles -Name $entry.Name -Enabled $Enabled -Role $Role
}

function Set-ComposeProvider {
    # Lists one database provider: its provider file, or in a platform stack its shared marker.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][ValidateSet('postgres', 'mysql', 'sqlserver')][string]$Provider,
        [ValidateSet('', 'services', 'platform', IgnoreCase = $false)][AllowEmptyString()][string]$Role = ''
    )

    $providerEntries = @($script:ComposeFileCatalog |
            Where-Object { $_.Kind -in 'provider', 'shared' -and $_.Feature -in $script:DbProviders -and $_.Roles -ccontains $Role })
    $providerNames = @($providerEntries | ForEach-Object { $_.Name })
    $others = @($ComposeFiles | Where-Object { $providerNames -cnotcontains $_ })
    $name = ($providerEntries | Where-Object { $_.Feature -eq $Provider }).Name
    Update-ComposeFileListKeepingState -ComposeFiles (@($others) + $name) -Previous $ComposeFiles -Role $Role
}

function Set-ComposeHttps {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][bool]$Enabled,
        [ValidateSet('', 'services', 'platform', IgnoreCase = $false)][AllowEmptyString()][string]$Role = ''
    )

    Set-ComposeFile -ComposeFiles $ComposeFiles -Name $script:ComposeHttpsFile -Enabled $Enabled -Role $Role
}

function Get-DefaultComposeFiles {
    # The default list of a standalone stack, or of a services stack (-Role services): the servers, no platform or storefront.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('postgres', 'mysql', 'sqlserver')][string]$Provider,
        [Parameter(Position = 1)][bool]$Https = $true,
        [ValidateSet('', 'services', IgnoreCase = $false)][AllowEmptyString()][string]$Role = ''
    )

    $names = [System.Collections.Generic.List[string]]::new()
    $names.Add((Get-ComposeFileName 'yml'))
    if ($Https) {
        $names.Add($script:ComposeHttpsFile)
    }
    $names.Add((Get-ComposeFileName "$Provider.yml"))
    $features = if ($Role -ceq 'services') { 'elasticsearch', 'kibana', 'redis' } else { 'platform', 'elasticsearch', 'kibana', 'redis', 'frontend' }
    foreach ($feature in $features) {
        $names.Add((Get-ComposeFileName "$feature.yml"))
    }
    Update-ComposeFileList -ComposeFiles $names.ToArray() -HasSourceModules $false -Role $Role
}

function Get-ServicesAnchorEntry {
    # The COMPOSE_FILE entry that points a platform stack at its services folder's docker-compose.yml (P1): the relative
    # path from the platform folder, with '/' separators. Absolute when no relative path exists (another Windows drive).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$ServicesFolder,
        [Parameter(Mandatory, Position = 1)][string]$SolutionFolder
    )

    $solutionPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($SolutionFolder)
    $anchorPath = Join-Path (Resolve-ServicesFolder -Value $ServicesFolder -SolutionFolder $solutionPath) (Get-ComposeFileName 'yml')
    [System.IO.Path]::GetRelativePath($solutionPath, $anchorPath).Replace('\', '/')
}

function Sync-PlatformComposeFiles {
    # Brings a platform stack's list in line with its services stack (S5): the anchor first and the old one gone; the
    # provider marker the services stack's provider; https.yml listed exactly when the services stack has it; none of the
    # services stack's server files. The Elasticsearch and Redis markers stay as the user set them (S17: preflight checks
    # that the services stack runs what they name).
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][pscustomobject]$ServicesInfo,
        [Parameter(Mandatory, Position = 2)][string]$SolutionFolder
    )

    $anchor = Get-ServicesAnchorEntry -ServicesFolder $ServicesInfo.Folder -SolutionFolder $SolutionFolder
    $previousAnchor = Get-ListedServicesAnchor $ComposeFiles
    # The files a standalone stack and a services stack share and a platform stack never lists: the servers.
    $serverEntries = @($script:ComposeFileCatalog | Where-Object { $_.Roles -ccontains '' -and $_.Roles -ccontains 'services' -and $_.Roles -cnotcontains 'platform' })
    $markerNames = @($script:ComposeFileCatalog | Where-Object { $_.Kind -ceq 'shared' -and $_.Feature -in $script:DbProviders } | ForEach-Object { $_.Name })

    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $ComposeFiles) {
        $serverEntry = $serverEntries | Where-Object { $_.Name -ceq $file }
        if ($serverEntry -and $serverEntry.Kind -in 'provider', 'feature', 'optin') {
            Write-Warning "$file is a server of the services stack; a platform stack lists none of them (STACK_ROLE is platform). Dropped it."
        }
        if (-not $serverEntry -and $file -cne $previousAnchor -and $file -cne $anchor -and $markerNames -cnotcontains $file -and $file -cne $script:ComposeHttpsFile) {
            $files.Add($file)
        }
    }
    $provider = $ServicesInfo.Features.Provider
    if ($provider) {
        $files.Add(($script:ComposeFileCatalog | Where-Object { $_.Kind -ceq 'shared' -and $_.Feature -eq $provider }).Name)
    }
    if ($ServicesInfo.Features.Https) {
        $files.Add($script:ComposeHttpsFile)
    }
    Update-ComposeFileList -ComposeFiles $files.ToArray() -HasSourceModules (Test-ComposeHasSourceModules $ComposeFiles) `
        -Role platform -ServicesAnchor $anchor -GeneratedFiles (Get-ListedGeneratedFiles $ComposeFiles)
}

function Get-DefaultPlatformComposeFiles {
    # A platform stack's first list (P16): the services stack's provider, HTTPS mode, and the servers it runs; the Docker
    # platform when the platform runs in Docker; the storefront.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][pscustomobject]$ServicesInfo,
        [Parameter(Mandatory, Position = 1)][ValidateSet('docker', 'source', 'skipped')][string]$PlatformMode,
        [Parameter(Mandatory, Position = 2)][string]$SolutionFolder
    )

    $features = $ServicesInfo.Features
    $names = [System.Collections.Generic.List[string]]::new()
    $names.Add((Get-ComposeFileName 'yml'))
    $names.Add((Get-ComposeFileName 'shared-network.yml'))
    if ($features.Provider) {
        $names.Add((Get-ComposeFileName "shared-$($features.Provider).yml"))
    }
    if ($features.Https) {
        $names.Add($script:ComposeHttpsFile)
    }
    foreach ($server in 'elasticsearch', 'redis') {
        if ($features.$server) {
            $names.Add((Get-ComposeFileName "shared-$server.yml"))
        }
    }
    if ($PlatformMode -eq 'docker') {
        $names.Add((Get-ComposeFileName 'platform.yml'))
    }
    $names.Add((Get-ComposeFileName 'frontend.yml'))
    Update-ComposeFileList -ComposeFiles $names.ToArray() -HasSourceModules $false -Role platform `
        -ServicesAnchor (Get-ServicesAnchorEntry -ServicesFolder $ServicesInfo.Folder -SolutionFolder $SolutionFolder)
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
    $suffixes = 'postgres_data', 'mysql_data', 'mssql_data', 'cms-content-data', 'assets-data', 'modules-data', 'esdata01', 'redisdata', 'certs'
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
    # The paths under <Folder> that `remove -keepData` deletes (F6): everything except .env, vc-package.json (the last
    # build's manifest: the kept database is migrated up to its versions, and the next build must not go below them)
    # and the user's own compose files that COMPOSE_FILE names (entries outside the catalog, Update-ComposeFileList keeps
    # them too; an entry outside the folder, a platform stack's services anchor, is skipped). A folder that
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
    $null = $kept.Add((Get-PackageManifestPath -SolutionFolder $folderPath))
    if ($Document) {
        $insidePrefix = [System.IO.Path]::TrimEndingDirectorySeparator($folderPath) + [System.IO.Path]::DirectorySeparatorChar
        foreach ($entry in (Get-EnvComposeFiles $Document)) {
            if (-not $script:ComposeFileCatalogNames.Contains($entry)) {
                $keptPath = [System.IO.Path]::GetFullPath($entry, $folderPath)
                # An entry outside the folder, like a platform stack's services anchor, is no file of this folder's to keep.
                if ($keptPath.StartsWith($insidePrefix, $comparison)) {
                    $null = $kept.Add($keptPath)
                }
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
