# The platform settings derived from .env, for a platform run from source (SPEC §5.3, §7.2).
#
# The compose YAML defines the same settings for the Docker platform; a drift test keeps the two equal.
# Settings are a flat, ordered table keyed like .NET configuration ('Section:Key'). The Container topology
# is what the compose files give the platform (services by name, fixed container ports). The Host topology
# is a platform on the host machine (services on localhost, published ports) and adds the keys only that
# platform needs.

function Get-EnvSettingValue {
    # A .env value, or the default when the key is missing or empty.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Default
    )

    if ($EnvValues.Contains($Key) -and -not [string]::IsNullOrEmpty([string]$EnvValues[$Key])) {
        return [string]$EnvValues[$Key]
    }
    $Default
}

function Get-RequiredEnvSecret {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not $EnvValues.Contains($Key) -or [string]::IsNullOrEmpty([string]$EnvValues[$Key])) {
        throw [System.InvalidOperationException]::new("$Key is empty in .env; the platform settings need it.")
    }
    [string]$EnvValues[$Key]
}

function Get-DbSettings {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('postgres', 'mysql', 'sqlserver')][string]$Provider,
        [Parameter(Mandatory, Position = 1)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 2)][ValidateSet('Container', 'Host')][string]$Topology
    )

    $password = Get-RequiredEnvSecret -EnvValues $EnvValues -Key 'DB_PASSWORD'
    $hostSide = $Topology -eq 'Host'
    $server = if ($hostSide) { 'localhost' } else { 'vc-db' }
    $portEntry = Get-PortEntry -Provider $Provider
    $portKey = $portEntry.Key
    $containerPort = [string]$portEntry.ContainerPort
    $port = if ($hostSide) { Get-EnvSettingValue -EnvValues $EnvValues -Key $portKey -Default $containerPort } else { $containerPort }

    switch ($Provider) {
        'postgres' {
            $name = 'PostgreSql'
            $connection = "User ID=postgres;Password=$password;Host=$server;Port=$port;Database=VirtoCommerce3"
        }
        'mysql' {
            $name = 'MySql'
            $connection = "Server=$server;Port=$port;Database=VirtoCommerce3;User=root;Password=$password"
        }
        'sqlserver' {
            $name = 'SqlServer'
            $connection = "Server=$server,$port;Database=VirtoCommerce3;User Id=sa;Password=$password;TrustServerCertificate=True"
        }
    }

    [ordered]@{
        'DatabaseProvider'                = $name
        'ConnectionStrings:VirtoCommerce' = $connection
    }
}

function Get-PlatformSettings {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 2)][ValidateSet('Container', 'Host')][string]$Topology,
        [Parameter(Position = 3)][string]$CaFingerprint,
        # Host topology: a second address the platform listens on, for the storefront in Docker (Get-DockerBridgeBindAddress).
        [string]$BridgeAddress
    )

    $features = Get-ComposeFeatures -ComposeFiles $ComposeFiles
    if (-not $features.Provider) {
        throw [System.InvalidOperationException]::new('COMPOSE_FILE lists no database provider. List exactly one of docker-compose/postgres.yml, docker-compose/mysql.yml, docker-compose/sqlserver.yml.')
    }

    $hostSide = $Topology -eq 'Host'
    $scheme = if ($features.Https) { 'https' } else { 'http' }
    $platformPort = Get-EnvSettingValue -EnvValues $EnvValues -Key 'PLATFORM_PORT' -Default (Get-PortDefault 'PLATFORM_PORT')

    $settings = Get-DbSettings -Provider $features.Provider -EnvValues $EnvValues -Topology $Topology
    $settings['VirtoCommerce:AllowInsecureHttp'] = if ($features.Https) { 'false' } else { 'true' }
    $settings['VirtoCommerce:Hangfire:JobStorageType'] = 'Memory'
    $settings['Assets:FileSystem:PublicUrl'] = "${scheme}://localhost:$platformPort/assets/"
    $settings['Content:FileSystem:PublicUrl'] = "${scheme}://localhost:$platformPort/cms-content/"

    if ($features.Elasticsearch) {
        $searchProvider = Get-EnvSettingValue -EnvValues $EnvValues -Key 'SEARCH_PROVIDER' -Default 'ElasticSearch8'
        if ($searchProvider -cnotin 'ElasticSearch8', 'ElasticSearch9') {
            throw [System.InvalidOperationException]::new("SEARCH_PROVIDER is '$searchProvider' in .env; use ElasticSearch8 or ElasticSearch9.")
        }
        $server = if ($hostSide) {
            "${scheme}://localhost:$(Get-EnvSettingValue -EnvValues $EnvValues -Key 'ES_PORT' -Default (Get-PortDefault 'ES_PORT'))"
        }
        else {
            "${scheme}://es:$((Get-PortEntry -Key 'ES_PORT').ContainerPort)"
        }
        $settings['Search:Provider'] = $searchProvider
        $settings["Search:${searchProvider}:Server"] = $server
        $settings["Search:${searchProvider}:User"] = 'elastic'
        $settings["Search:${searchProvider}:Key"] = Get-RequiredEnvSecret -EnvValues $EnvValues -Key 'ELASTIC_PASSWORD'
        if ($hostSide -and $CaFingerprint) {
            $settings["Search:${searchProvider}:CertificateFingerprint"] = $CaFingerprint
        }
    }

    if ($features.Redis) {
        $redisServer = if ($hostSide) {
            "localhost:$(Get-EnvSettingValue -EnvValues $EnvValues -Key 'REDIS_PORT' -Default (Get-PortDefault 'REDIS_PORT'))"
        }
        else {
            "redis:$((Get-PortEntry -Key 'REDIS_PORT').ContainerPort)"
        }
        $settings['ConnectionStrings:RedisConnectionString'] = "$redisServer,password=$(Get-RequiredEnvSecret -EnvValues $EnvValues -Key 'REDIS_PASSWORD')"
    }

    if ($hostSide) {
        $bindAddress = Get-EnvSettingValue -EnvValues $EnvValues -Key 'BIND_ADDRESS' -Default '127.0.0.1'
        $settings['Kestrel:Endpoints:Main:Url'] = "${scheme}://${bindAddress}:$platformPort"
        # A wildcard BIND_ADDRESS already covers the bridge, and a second bind of the same address and port would fail.
        if ($BridgeAddress -and $bindAddress -notin '0.0.0.0', '::', '*', $BridgeAddress) {
            $settings['Kestrel:Endpoints:Bridge:Url'] = "${scheme}://${BridgeAddress}:$platformPort"
        }
    }

    $settings
}

function ConvertTo-SettingsJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$Flat
    )

    $root = [ordered]@{}
    foreach ($key in $Flat.Keys) {
        $segments = $key.Split(':')
        $node = $root
        for ($index = 0; $index -lt $segments.Count - 1; $index++) {
            $segment = $segments[$index]
            if (-not $node.Contains($segment)) {
                $node[$segment] = [ordered]@{}
            }
            elseif ($node[$segment] -isnot [System.Collections.IDictionary]) {
                throw [System.InvalidOperationException]::new("Settings key '$key' conflicts with the value of '$($segments[0..$index] -join ':')'.")
            }
            $node = $node[$segment]
        }
        $leaf = $segments[-1]
        if ($node.Contains($leaf) -and $node[$leaf] -is [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new("Settings key '$key' conflicts with the section of the same name.")
        }
        $node[$leaf] = $Flat[$key]
    }
    $root | ConvertTo-Json -Depth 20
}

function Get-SettingsFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$PlatformPath,
        [Parameter(Mandatory, Position = 1)][ValidateSet('checkout', 'prebuilt')][string]$Kind
    )

    Join-Path (Get-PlatformContentRoot -Path $PlatformPath -Kind $Kind) 'VirtoCommerce.Platform.Web.settings.json'
}

function Write-PlatformSettingsFile {
    # Writes the settings table as the platform's settings file (UTF-8, no byte order mark). The platform reloads it on change.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][System.Collections.IDictionary]$Flat
    )

    [System.IO.File]::WriteAllText($Path, (ConvertTo-SettingsJson -Flat $Flat) + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Get-PlatformUserSecretsPath {
    # The user-secrets file of VirtoCommerce.Platform.Web: one store per machine, shared by every checkout and build (FC §12).
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($IsWindows) {
        return Join-Path $env:APPDATA 'Microsoft\UserSecrets\VirtoCommerce.Platform.Web\secrets.json'
    }
    Join-Path $HOME '.microsoft/usersecrets/VirtoCommerce.Platform.Web/secrets.json'
}

function Get-ShadowedKeys {
    # The setting keys that the user-secrets JSON also defines. Secrets override the settings file, so these keys never take
    # their value from it. Keys compare without case, as .NET configuration does. Valid JSON that is not an object gives
    # none. Throws FormatException for what the platform would fail to start on too: text that is not JSON, and one
    # setting defined twice under names that differ only in case.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$SecretsJson,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$SettingKeys
    )

    try {
        # -AsHashtable: objects become dictionaries, which take keys that differ only in case (PSCustomObject refuses them).
        $secrets = $SecretsJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    # Text that is not JSON: ConvertFrom-Json throws ArgumentException, which -ErrorAction Stop hands over wrapped in a
    # RuntimeException.
    catch [System.Management.Automation.RuntimeException], [System.ArgumentException] {
        throw [System.FormatException]::new("The user secrets are not valid JSON: $($_.Exception.Message)", $_.Exception)
    }
    if ($secrets -isnot [System.Collections.IDictionary]) {
        return , [string[]]@()
    }

    $secretKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $pending = [System.Collections.Generic.Stack[object]]::new()
    $pending.Push(@{ Prefix = ''; Node = $secrets })
    while ($pending.Count -gt 0) {
        $item = $pending.Pop()
        foreach ($property in $item.Node.GetEnumerator()) {
            $key = "$($item.Prefix)$($property.Key)"
            if ($property.Value -is [System.Collections.IDictionary]) {
                $pending.Push(@{ Prefix = "${key}:"; Node = $property.Value })
            }
            elseif (-not $secretKeys.Add($key)) {
                # .NET's JSON configuration reader keeps its keys without case and refuses a second value for one.
                # (A key repeated in the same case is not seen here: ConvertFrom-Json keeps its last value.)
                throw [System.FormatException]::new("The user secrets define '$key' more than once, under names that differ only in case. .NET configuration refuses that.")
            }
        }
    }
    , [string[]]@($SettingKeys | Where-Object { $secretKeys.Contains($_) })
}

function Get-ContainerOnlyKeys {
    # Compose keys of the Docker platform that the source platform's settings never carry.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    [string[]]@('ASPNETCORE_URLS', 'Kestrel:Certificates:Default:Path', 'Kestrel:Certificates:Default:KeyPath', 'SSL_CERT_DIR')
}
