# Preflight checks and the service listing of a stack (SPEC §8.1, §11).
#
# Each check returns a message that names its fix; Invoke-Preflight collects them and the caller prints them.

function Test-PortInUse {
    # True when a TCP listener on this machine already uses the port.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][int]$Port
    )

    $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    @($listeners | Where-Object { $_.Port -eq $Port }).Count -gt 0
}

function Get-DockerDaemonError {
    # Why the Docker daemon does not answer, in Docker's own words (not running, socket permission denied, ...).
    # $null when it answers.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Get-Command docker -ErrorAction Ignore)) {
        return "the 'docker' command is not installed"
    }
    $output = & docker info --format '{{.ServerVersion}}' 2>&1
    if ($LASTEXITCODE -eq 0) {
        return $null
    }
    ConvertTo-NativeMessage $output "'docker info' failed with exit code $LASTEXITCODE"
}

function ConvertTo-PublishedPorts {
    # The published host ports in `docker compose ps --format json` output: one JSON object per line
    # (Compose 2.21 and later) or one JSON array (older).
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Json
    )

    $text = ($Json | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) {
        return , [int[]]@()
    }
    $containers = if ($text.TrimStart().StartsWith('[')) {
        $text | ConvertFrom-Json
    }
    else {
        $text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json }
    }
    $ports = foreach ($container in $containers) {
        foreach ($publisher in $container.Publishers) {
            if ([int]$publisher.PublishedPort -gt 0) {
                [int]$publisher.PublishedPort
            }
        }
    }
    , [int[]]@($ports | Sort-Object -Unique)
}

function Get-ProjectPublishedPorts {
    # The host ports the running containers of this folder's Compose project publish (run it in the solution folder).
    # Throws InvalidOperationException with Compose's message when Compose cannot read the project.
    [CmdletBinding()]
    [OutputType([int[]])]
    param()

    $output = & docker compose ps --format json 2>&1
    $lines = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        $message = ConvertTo-NativeMessage @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) ''
        throw [System.InvalidOperationException]::new("'docker compose ps' failed (exit code $LASTEXITCODE): $message")
    }
    ConvertTo-PublishedPorts -Json ([string[]]$lines)
}

function Get-RequiredPorts {
    # The host ports the stack needs free: one per listed service (and a source platform; not a skipped one), minus
    # ExcludePorts. Returns [pscustomobject]@{ Key; Port } entries. Throws FormatException when a needed port key is
    # empty, or is not a number from 1 to 65535.
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Position = 2)][int[]]$ExcludePorts = @()
    )

    $features = Get-ComposeFeatures -ComposeFiles $ComposeFiles
    # A skipped platform is the user's own: its port is theirs to hold.
    $platformMode = Get-PlatformMode -EnvValues $EnvValues
    $needsPlatformPort = ($features.Platform -and $platformMode -eq 'docker') -or $platformMode -eq 'source'

    $required = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $script:PortCatalog) {
        $needed = if ($entry.Provider) { $features.Provider -eq $entry.Provider }
        elseif ($entry.Key -eq 'PLATFORM_PORT') { $needsPlatformPort }
        else { $ComposeFiles -ccontains $entry.File }
        if (-not $needed) {
            continue
        }

        $text = [string]$EnvValues[$entry.Key]
        if ([string]::IsNullOrWhiteSpace($text)) {
            # Compose publishes an empty port as a random one, while the scripts would print the standard one.
            throw [System.FormatException]::new("$($entry.Key) is empty in .env, so Docker would pick a random port. Set it to a port number (the standard one is $($entry.Default)).")
        }
        $port = 0
        if (-not [int]::TryParse($text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            throw [System.FormatException]::new("$($entry.Key) is '$text' in .env; it must be a port number from 1 to 65535.")
        }
        if ($ExcludePorts -notcontains $port) {
            $required.Add([pscustomobject]@{ Key = $entry.Key; Port = $port })
        }
    }
    , [pscustomobject[]]$required.ToArray()
}

function Test-EnvValues {
    # Checks the .env values that would fail later, deep in startup, or silently differ between the scripts and Compose.
    # Returns one message per problem, naming the key and the rule; empty when all is well.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @($script:SecretKeys) + 'ADMIN_PASSWORD') {
        if (([string]$EnvValues[$key]).Contains('$')) {
            $errors.Add("$key in .env contains '`$'. Compose replaces `$name with a variable while the scripts read it as typed, so the two would use different passwords. Remove the '`$'.")
        }
    }

    # The platform's rule (ASP.NET Identity defaults with IdentityOptions:Password): 8+ characters, an uppercase and a
    # lowercase letter. An empty ADMIN_PASSWORD is generated.
    $adminPassword = [string]$EnvValues['ADMIN_PASSWORD']
    if ($adminPassword -and ($adminPassword.Length -lt 8 -or $adminPassword -cnotmatch '[A-Z]' -or $adminPassword -cnotmatch '[a-z]')) {
        $errors.Add('ADMIN_PASSWORD in .env breaks the platform''s password rule: at least 8 characters, with an uppercase and a lowercase letter. Change it, or empty it to have one generated.')
    }

    $provider = $null
    try {
        $provider = Resolve-DbProvider -ComposeFiles $ComposeFiles
        if (-not $provider) {
            $errors.Add("COMPOSE_FILE lists no database. Add one of $(($script:DbProviders | ForEach-Object { Get-ComposeFileName "$_.yml" }) -join ', ').")
        }
    }
    catch [System.InvalidOperationException] {
        $errors.Add($_.Exception.Message)
    }

    # SQL Server's policy: 8+ characters from at least 3 of uppercase, lowercase, digits and symbols.
    $dbPassword = [string]$EnvValues['DB_PASSWORD']
    if ($provider -eq 'sqlserver' -and $dbPassword) {
        $classes = @('[A-Z]', '[a-z]', '[0-9]', '[^A-Za-z0-9]' | Where-Object { $dbPassword -cmatch $_ }).Count
        if ($dbPassword.Length -lt 8 -or $classes -lt 3) {
            $errors.Add('DB_PASSWORD in .env breaks SQL Server''s password policy: at least 8 characters from 3 of uppercase, lowercase, digits and symbols. Change it, or empty it to have one generated.')
        }
    }

    # Files of the old root layout, such as docker-compose.kibana.yml, now live in docker-compose/.
    $catalogNames = @($script:ComposeFileCatalog | ForEach-Object { $_.Name })
    foreach ($file in $ComposeFiles) {
        $match = [regex]::Match($file, '^docker-compose\.(?<feature>.+)\.yml$')
        if (-not $match.Success) {
            continue
        }
        $newName = Get-ComposeFileName "$($match.Groups['feature'].Value).yml"
        if ($catalogNames -ccontains $newName) {
            $errors.Add("COMPOSE_FILE lists $file, which is now $newName. Rename it in .env.")
        }
    }

    , $errors.ToArray()
}

function Get-ServiceUrls {
    # The URLs of the services a run makes available, as [pscustomobject]@{ Name; Url }. The platform is always listed.
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    $features = Get-ComposeFeatures -ComposeFiles $ComposeFiles
    $scheme = if ($features.Https) { 'https' } else { 'http' }

    # Every stack has a platform: in Docker, from source, or run by the user (skipped), always on PLATFORM_PORT.
    $listed = @{ Platform = $true; Storefront = $features.Frontend; Elasticsearch = $features.Elasticsearch; Kibana = $features.Kibana }
    $urls = foreach ($entry in @($script:PortCatalog | Where-Object { $_.Name })) {
        if ($listed[$entry.Name]) {
            $port = Get-EnvSettingValue -EnvValues $EnvValues -Key $entry.Key -Default (Get-PortDefault $entry.Key -Https $features.Https)
            [pscustomobject]@{ Name = $entry.Name; Url = "${scheme}://localhost:$port" }
        }
    }
    , [pscustomobject[]]@($urls)
}

function Invoke-Preflight {
    # Runs the checks and returns the errors, each naming its fix; an empty array means go.
    # Run it in the solution folder: the published-ports query uses its Compose project.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 2)][bool]$NonInteractive
    )

    # The other checks read these values; with a broken .env their results would mislead.
    $valueErrors = Test-EnvValues -EnvValues $EnvValues -ComposeFiles $ComposeFiles
    if ($valueErrors.Count -gt 0) {
        return , [string[]]$valueErrors
    }

    $errors = [System.Collections.Generic.List[string]]::new()

    try {
        $composeVersion = Get-ComposeVersion
        if (-not (Test-ComposeVersion $composeVersion $script:ComposeMinimumVersion)) {
            $errors.Add("Docker Compose $composeVersion is too old: $($script:ComposeMinimumVersion) or later is required. Update Docker Desktop, or install the Compose plugin v$($script:ComposeMinimumVersion)+ (https://docs.docker.com/compose/install/).")
        }
    }
    catch [System.InvalidOperationException] {
        $errors.Add("'docker compose' (the Compose plugin) is not available: $($_.Exception.Message) Install Docker with Compose $($script:ComposeMinimumVersion) or later (https://docs.docker.com/compose/install/).")
    }

    $dockerError = Get-DockerDaemonError
    $dockerRunning = -not $dockerError
    if ($dockerError) {
        $errors.Add("Docker is not reachable: $dockerError. Start Docker Desktop (or the Docker daemon), or fix the reason above, and run again.")
    }

    $ownPorts = [int[]]@()
    $projectReadable = $true
    if ($dockerRunning) {
        try {
            $ownPorts = Get-ProjectPublishedPorts
        }
        catch [System.InvalidOperationException] {
            # Without the project, its own ports look foreign: report Compose's reason instead of false port conflicts.
            $errors.Add("Docker Compose cannot read this folder's project. Fix the cause, then run again. $($_.Exception.Message)")
            $projectReadable = $false
        }
    }
    $platformMode = Get-PlatformMode -EnvValues $EnvValues
    # A skipped platform with a source path still gets its settings file and module links (B6).
    $hasSourcePath = -not [string]::IsNullOrWhiteSpace([string]$EnvValues['PLATFORM_SOURCE_PATH'])
    if ($platformMode -eq 'source' -and (Get-RunningSourcePlatform -LogDir (Get-SourcePlatformLogDir -SolutionFolder (Get-Location).ProviderPath))) {
        # A re-run: the platform this folder started earlier holds its port, and start restarts it.
        $platformPort = 0
        if ([int]::TryParse((Get-EnvSettingValue -EnvValues $EnvValues -Key 'PLATFORM_PORT' -Default (Get-PortDefault 'PLATFORM_PORT')).Trim(), [ref]$platformPort)) {
            $ownPorts = [int[]]@($ownPorts + $platformPort)
        }
    }
    try {
        $requiredPorts = Get-RequiredPorts -EnvValues $EnvValues -ComposeFiles $ComposeFiles -ExcludePorts $ownPorts
    }
    catch [System.FormatException] {
        $errors.Add($_.Exception.Message)
        $requiredPorts = @()
    }
    foreach ($required in $requiredPorts) {
        if ($projectReadable -and (Test-PortInUse -Port $required.Port)) {
            $errors.Add("Port $($required.Port) ($($required.Key)) is already in use. Stop the program that uses it, or set another $($required.Key) in .env.")
        }
    }

    $moduleSources = Get-ModuleSourceKind -Paths (Split-ModuleSourcePaths ([string]$EnvValues['MODULE_SOURCE_PATHS']))
    if ($moduleSources.Kind -in 'mixed', 'invalid') {
        $errors.Add($moduleSources.Message)
    }
    elseif ($dockerRunning -and (Get-ComposeFeatures -ComposeFiles $ComposeFiles).Platform) {
        # Only a Docker platform bind-mounts the sources (SPEC §7.3), and Docker Desktop refuses folders outside its File Sharing list.
        foreach ($mount in (Get-ModuleMountPlan -Classification $moduleSources)) {
            try {
                $shared = Test-FileSharing -Path $mount.Source
            }
            catch {
                $errors.Add("File sharing: could not check whether Docker can mount '$($mount.Source)' (MODULE_SOURCE_PATHS): $($_.Exception.Message)")
                continue
            }
            if (-not $shared) {
                $errors.Add("File sharing: Docker cannot mount '$($mount.Source)' (MODULE_SOURCE_PATHS). Add its folder to Docker Desktop > Settings > Resources > File sharing, then run again.")
            }
        }
    }

    if ($hasSourcePath) {
        $platformPath = Resolve-PlatformSourcePath -Value ([string]$EnvValues['PLATFORM_SOURCE_PATH'])
        $platformKind = Get-PlatformSourceKind -Path $platformPath
        if (-not $platformKind) {
            $errors.Add("PLATFORM_SOURCE_PATH '$platformPath' is neither a vc-platform checkout (it has no src/VirtoCommerce.Platform.Web/VirtoCommerce.Platform.Web.csproj) nor a prebuilt platform folder (it has no VirtoCommerce.Platform.Web.dll). Fix the path in .env.")
        }
        else {
            # H6: start only runs what is built. A skipped platform is built and run by the user (B6).
            $contentRoot = Get-PlatformContentRoot -Path $platformPath -Kind $platformKind
            if ($platformMode -eq 'source' -and -not (Test-PlatformBuildOutput -Path $platformPath -Kind $platformKind)) {
                $errors.Add("The platform is not built: '$contentRoot' has no build output (bin/**/VirtoCommerce.Platform.Web.dll). Build it with dotnet build or from your IDE, then run again.")
            }
            $linkPlan = Get-ModuleLinkPlan -Classification $moduleSources -ContentRoot $contentRoot
            if ($linkPlan.Count -gt 0 -and -not (Test-SymlinkRights)) {
                $errors.Add('MODULE_SOURCE_PATHS needs directory symlinks, which this shell cannot create. Enable Developer Mode or run an elevated shell, then run again.')
            }
        }
    }

    if ($NonInteractive) {
        foreach ($key in (Get-MissingRequiredKeys -EnvValues $EnvValues -ForStart)) {
            $errors.Add("$key is empty in .env. Set it, or pass the matching parameter.")
        }
    }

    , $errors.ToArray()
}
