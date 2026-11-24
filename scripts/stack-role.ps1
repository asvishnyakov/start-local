# The stack roles (S1) and the rules of a platform stack's .env.
#
# STACK_ROLE is empty (a standalone stack), 'services' (one set of servers) or 'platform' (a platform that uses a
# services stack). A platform stack's Compose project reads two .env files: its own, and the services folder's one as a
# second, lower-precedence file (S5, P1). A key present in the platform .env, even an empty one, wins over the services
# value; an absent key takes it (P2). So the platform .env holds no key the services stack owns, and every other key.

# The keys the services stack owns (S5a): the secrets, the server versions and ports, and the two names the services
# start writes (P5). A platform .env must not hold them.
$script:ServicesOwnedKeys = @($script:SecretKeys) + @(
    'PGSQL_VERSION', 'PGSQL_PORT', 'MYSQL_VERSION', 'MYSQL_PORT', 'MSSQL_VERSION', 'MSSQL_PORT',
    'STACK_VERSION', 'ES_PORT', 'KIBANA_PORT', 'ES_MEM_LIMIT', 'REDIS_PORT', 'SERVICES_NETWORK_NAME', 'SERVICES_CERTS_VOLUME'
)

function Get-StackRole {
    # '' (standalone), 'services' or 'platform'. The case matters, like SKIP_PLATFORM's 'true': a role that read as
    # standalone by mistake would start the stack with its own servers.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues
    )

    $role = ([string]$EnvValues['STACK_ROLE']).Trim()
    if ($role -cin '', 'services', 'platform') {
        return $role
    }
    throw [System.InvalidOperationException]::new("STACK_ROLE in .env is '$role'; expected services, platform, or empty (lower case).")
}

function Get-ServicesOwnedKeys {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    , [string[]]$script:ServicesOwnedKeys
}

function Resolve-ServicesFolder {
    # SERVICES_FOLDER as an absolute path: an absolute value as it is, a relative one against the platform stack's folder,
    # never the current location.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Value,
        [Parameter(Mandatory, Position = 1)][string]$SolutionFolder
    )

    $baseFolder = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($SolutionFolder)
    [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Value.Trim(), $baseFolder))
}

function Get-ServicesStackInfo {
    # What a platform stack needs to know of its services stack, read from the services folder's .env; $null when the
    # folder has no .env or its STACK_ROLE is not 'services'. NetworkName and CertsVolume are the two keys the services
    # start writes (P5): empty before its first start.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$ServicesFolder
    )

    $envPath = Join-Path $ServicesFolder '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        return $null
    }
    $document = Read-EnvFile -Path $envPath
    $table = Get-EnvTable -Document $document
    if ((Get-StackRole -EnvValues $table) -cne 'services') {
        return $null
    }

    [pscustomobject]@{
        Folder      = $ServicesFolder
        ProjectName = Get-SolutionProjectName -Document $document -SolutionFolder $ServicesFolder
        Features    = Get-ComposeFeatures -ComposeFiles (Get-EnvComposeFiles -Document $document)
        NetworkName = [string]$table['SERVICES_NETWORK_NAME']
        CertsVolume = [string]$table['SERVICES_CERTS_VOLUME']
        EnvTable    = $table
    }
}

function Get-StackEnvTable {
    # The values Compose sees for the stack of $Document. A platform stack: the services .env first, then every key the
    # platform .env holds on top, empty ones included (P2). Any other role, or a platform stack whose services folder
    # is unset or not a services stack: the table of $Document alone.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$SolutionFolder
    )

    $table = Get-EnvTable -Document $Document
    if ((Get-StackRole -EnvValues $table) -cne 'platform' -or [string]::IsNullOrWhiteSpace([string]$table['SERVICES_FOLDER'])) {
        return $table
    }
    $servicesInfo = Get-ServicesStackInfo -ServicesFolder (Resolve-ServicesFolder -Value $table['SERVICES_FOLDER'] -SolutionFolder $SolutionFolder)
    if (-not $servicesInfo) {
        return $table
    }

    $merged = [ordered]@{}
    foreach ($key in $servicesInfo.EnvTable.Keys) {
        $merged[$key] = $servicesInfo.EnvTable[$key]
    }
    foreach ($key in $table.Keys) {
        $merged[$key] = $table[$key]
    }
    $merged
}

function Get-IsolationDefaults {
    # The per-stack values of a platform stack (S9, P11), derived from its Compose project name.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$ProjectName
    )

    @{
        DB_NAME           = "VirtoCommerce_$($ProjectName.Replace('-', '_'))"
        SEARCH_SCOPE      = $ProjectName
        REDIS_CHANNEL     = "VirtoCommerceChannel-$ProjectName"
        PLATFORM_HOSTNAME = "$($ProjectName.Replace('_', '-')).dev.internal"
    }
}

function Update-EnvForRole {
    # Brings the .env of $Document to what its STACK_ROLE needs; returns the keys it changed (none on a second call).
    #   platform:   the template's keys it lacks, except the services-owned ones (a deleted VOLUME_PREFIX comes back: Compose
    #               would take the services value); no services-owned key; COMPOSE_PROJECT_NAME, else the services
    #               project's name would name this stack; the empty isolation defaults (P11).
    #   services:   COMPOSE_PROJECT_NAME. Never the P5 keys: while they are empty, start knows no services start ran (P17).
    #   standalone: nothing.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$SolutionFolder,
        [Parameter(Mandatory, Position = 2)][psobject]$Template
    )

    $changed = [System.Collections.Generic.List[string]]::new()
    $role = Get-StackRole -EnvValues (Get-EnvTable -Document $Document)
    $setWhenEmpty = {
        param([string]$Key, [string]$Value)

        if ([string]::IsNullOrWhiteSpace((Get-EnvValue -Document $Document -Key $Key))) {
            Set-EnvValue -Document $Document -Key $Key -Value $Value
            $changed.Add($Key)
        }
    }

    switch ($role) {
        'platform' {
            $servicesOwned = Get-ServicesOwnedKeys
            $changed.AddRange([string[]](Add-MissingEnvKeys -Document $Document -Template $Template -ExcludeKeys $servicesOwned))
            foreach ($key in $servicesOwned) {
                if (Remove-EnvKey -Document $Document -Key $key) {
                    $changed.Add($key)
                }
            }
            & $setWhenEmpty 'COMPOSE_PROJECT_NAME' (Get-SolutionProjectName -Document $Document -SolutionFolder $SolutionFolder)
            $defaults = Get-IsolationDefaults -ProjectName (Get-SolutionProjectName -Document $Document -SolutionFolder $SolutionFolder)
            foreach ($key in $defaults.Keys) {
                & $setWhenEmpty $key $defaults[$key]
            }
        }
        'services' {
            & $setWhenEmpty 'COMPOSE_PROJECT_NAME' (Get-SolutionProjectName -Document $Document -SolutionFolder $SolutionFolder)
        }
    }
    , $changed.ToArray()
}

function Set-ServicesStackKeys {
    # The two names only the services stack sets (P5): its shared network (S3) and its certificates volume. The services
    # start calls it after preflight (P17). Returns the keys it changed.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$SolutionFolder
    )

    $names = [ordered]@{
        SERVICES_NETWORK_NAME = "$(Get-SolutionProjectName -Document $Document -SolutionFolder $SolutionFolder)-shared"
        SERVICES_CERTS_VOLUME = Get-CertsVolumeName -Document $Document -SolutionFolder $SolutionFolder
    }
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $names.Keys) {
        if ((Get-EnvValue -Document $Document -Key $key) -cne $names[$key]) {
            Set-EnvValue -Document $Document -Key $key -Value $names[$key]
            $changed.Add($key)
        }
    }
    , $changed.ToArray()
}
