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

    if (-not (Test-DockerCommand)) {
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
    # Compose loads the given files, not the COMPOSE_FILE of .env: start checks and runs the list it repaired, and a
    # hand-edited .env list may not load at all. No file gives no port. Throws InvalidOperationException with Compose's
    # message when Compose cannot read the project, a listed file that is missing included. Compose reports that only
    # when .env sets no COMPOSE_PROJECT_NAME (the default): with a name, `ps` finds the containers by it without reading
    # the files, and a broken list surfaces at `up`.
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    # The generated platform-modules.yml alone may be missing: start writes it after the preflight, and it adds bind
    # mounts, not ports. Any other missing file stays in, so that Compose can name it here and not only at `up`.
    $fileArguments = foreach ($file in $ComposeFiles) {
        if ($file -cne $script:ComposeModulesFile -or (Test-Path -LiteralPath $file -PathType Leaf)) { '-f'; $file }
    }
    if (-not $fileArguments) {
        # Without -f, Compose would load the COMPOSE_FILE of .env after all.
        return , [int[]]@()
    }
    # --project-directory: with -f alone, the folder of the first file decides which .env is read and the project name.
    $output = & docker compose --project-directory . @fileArguments ps --format json 2>&1
    $lines = @($output | Select-NativeStdout | ForEach-Object { [string]$_ })
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
            throw [System.FormatException]::new("$($entry.Key) is empty in .env, so Docker would pick a random port. Set it to a port number (the standard one is $(Get-PortDefault $entry.Key -Https $features.Https)).")
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
    # Returns one message per problem, naming the key and the rule; empty when all is well. -NonInteractive: the run
    # sets ADMIN_PASSWORD on the platform (C1), so its password rule applies; an interactive run only tries it.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Position = 2)][bool]$NonInteractive = $false
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $script:SecretKeys) {
        if (([string]$EnvValues[$key]).Contains('$')) {
            $errors.Add("$key in .env contains '`$'. Compose replaces `$name with a variable while the scripts read it as typed, so the two would use different passwords. Remove the '`$'.")
        }
    }
    # No compose file reads ADMIN_PASSWORD, but Compose reads all of .env.
    $adminPassword = [string]$EnvValues['ADMIN_PASSWORD']
    if ($adminPassword.Contains('$')) {
        $errors.Add("ADMIN_PASSWORD in .env contains '`$'. Compose reads all of .env and would warn on every run that the variable named by the text after the '`$' is not set. Remove the '`$'.")
    }

    # The platform's rule (ASP.NET Identity defaults with IdentityOptions:Password): 8+ characters, an uppercase and a
    # lowercase letter. An empty ADMIN_PASSWORD is generated.
    if ($NonInteractive -and $adminPassword -and ($adminPassword.Length -lt 8 -or $adminPassword -cnotmatch '[A-Z]' -or $adminPassword -cnotmatch '[a-z]')) {
        $errors.Add('ADMIN_PASSWORD in .env breaks the platform''s password rule: at least 8 characters, with an uppercase and a lowercase letter. Change it, or empty it to have one generated.')
    }

    # Get-PlatformMode reads only true as skipped: any other value would silently run the platform.
    $skipPlatform = ([string]$EnvValues['SKIP_PLATFORM']).Trim()
    if ($skipPlatform -and $skipPlatform -notin 'true', 'false') {
        $errors.Add("SKIP_PLATFORM in .env is '$skipPlatform'. Set it to true to skip the platform, or to false or empty to run it.")
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

function Get-MissingSolutionImages {
    # The images that ./build.ps1 builds for this folder (platform, storefront) which the listed services need and
    # Docker does not have. Compose would try to pull them, and fail with a registry error. Throws
    # InvalidOperationException with Docker's message when Docker cannot answer.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][string]$ProjectName
    )

    $features = Get-ComposeFeatures -ComposeFiles $ComposeFiles
    # Assigned first: piped straight from the call, the array the function returns wrapped (unary comma) would reach
    # Where-Object as one object; from a variable it is enumerated.
    $imageNames = Get-SolutionImageNames $ProjectName
    $needed = @($imageNames | Where-Object {
            ($features.Platform -and $_ -like 'vc-platform:*') -or ($features.Frontend -and $_ -like 'vc-frontend:*')
        })
    $missing = foreach ($image in $needed) {
        # `image ls` prints the id of an image Docker has and nothing for one it lacks, and exits 0 for both, so any
        # other exit code is Docker failing. (`image inspect` exits 1 for a missing image and for a failure alike.)
        $output = & docker image ls --quiet $image 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new("'docker image ls $image' failed: $(ConvertTo-NativeMessage $output "exit code $LASTEXITCODE")")
        }
        if (-not (@($output | Select-NativeStdout) -join '').Trim()) {
            $image
        }
    }
    , [string[]]@($missing)
}

function Get-KibanaPasswordWarning {
    # A warning when Kibana cannot sign in because es-setup has not set the kibana_system password (HTTPS mode only:
    # the HTTP stack has no security). $null when it is set, or when the stack has no secured Kibana. Run it in the
    # solution folder. -TimeoutSeconds: how long a record that is still pending gets to settle before the warning.
    # es-setup sets the password a few seconds after Elasticsearch turns healthy, which is when `up` returns, so a
    # start that does not wait for a platform would read the record too early.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [int]$TimeoutSeconds = 60
    )

    $features = Get-ComposeFeatures -ComposeFiles $ComposeFiles
    if (-not ($features.Https -and $features.Kibana)) {
        return $null
    }
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $output = Invoke-DockerCompose exec -T es-setup sh -c 'if [ -f /tmp/kibana-password-set ]; then echo set; elif [ -f /tmp/kibana-password-failed ]; then echo failed; else echo pending; fi' 2>&1
        # The else matters: an if without one leaves the variable empty (no value, not $null), and switch runs no
        # branch, not even default, for an empty value.
        $state = if ($LASTEXITCODE -eq 0) { (@($output | Select-NativeStdout) -join '').Trim() } else { '' }
        $settled = $state -ne 'pending' -or [datetime]::UtcNow -ge $deadline
        if (-not $settled) {
            Start-Sleep -Seconds 2
        }
    } until ($settled)
    switch ($state) {
        'set' { $null }
        # A running es-setup is not started again by `up`: only a new container, which stop and start give, retries.
        'failed' { 'es-setup gave up setting the kibana_system password, so Kibana cannot sign in. See docker compose logs es-setup, fix the cause (often ELASTIC_PASSWORD), then run ./stop.ps1 and ./start.ps1 to have es-setup try again.' }
        'pending' { 'es-setup has not set the kibana_system password yet, so Kibana cannot sign in until it does. If that lasts, see docker compose logs es-setup.' }
        default { "Could not check whether es-setup set the kibana_system password, so Kibana may not sign in: $(ConvertTo-NativeMessage $output "exit code $LASTEXITCODE")" }
    }
}

function Invoke-Preflight {
    # Runs the checks and returns the errors, each naming its fix; an empty array means go.
    # Run it in the solution folder: the published-ports query uses its Compose project. -ProjectName: also check that
    # the images the folder builds exist.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 2)][bool]$NonInteractive,
        [string]$ProjectName
    )

    # A required key left empty (for start: COMPOSE_FILE) is the cause: every other check would read the default list
    # start fills in for it and report misleading errors, so it is reported first and alone.
    if ($NonInteractive) {
        $missingKeys = Get-MissingRequiredKeys -EnvValues $EnvValues -ForStart
        if ($missingKeys.Count -gt 0) {
            return , [string[]]@($missingKeys | ForEach-Object { "$_ is empty in .env. Set it, or pass the matching parameter." })
        }
    }

    # The other checks read these values; with a broken .env their results would mislead.
    $valueErrors = Test-EnvValues -EnvValues $EnvValues -ComposeFiles $ComposeFiles -NonInteractive $NonInteractive
    if ($valueErrors.Count -gt 0) {
        return , [string[]]$valueErrors
    }

    $errors = [System.Collections.Generic.List[string]]::new()

    $dockerRunning = $false
    if (-not (Test-DockerCommand)) {
        # Nothing to ask without the command, neither the daemon nor Compose: installing Docker is the one fix.
        $errors.Add("The 'docker' command is not installed. Install Docker with Compose $($script:ComposeMinimumVersion) or later (https://docs.docker.com/compose/install/), then run again.")
    }
    else {
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
            $errors.Add("Docker is not reachable. Start Docker Desktop (or the Docker daemon), or fix the cause Docker gives, and run again. Docker says: $dockerError")
        }
    }

    $ownPorts = [int[]]@()
    $projectReadable = $true
    if ($dockerRunning) {
        try {
            $ownPorts = Get-ProjectPublishedPorts -ComposeFiles $ComposeFiles
        }
        catch [System.InvalidOperationException] {
            # Without the project, its own ports look foreign: report Compose's reason instead of false port conflicts.
            $errors.Add("Docker Compose cannot read this folder's project. Fix the cause, then run again. $($_.Exception.Message)")
            $projectReadable = $false
        }
        if ($ProjectName) {
            try {
                # Built, never pulled: a build that failed (say, right after a migration) leaves none.
                foreach ($image in (Get-MissingSolutionImages -ComposeFiles $ComposeFiles -ProjectName $ProjectName)) {
                    $errors.Add("The image $image does not exist, so Docker Compose would try to pull it and fail. Build it with ./build.ps1, then run again.")
                }
            }
            catch [System.InvalidOperationException] {
                $errors.Add("Docker could not tell whether the images this folder builds exist. Fix the cause, then run again. $($_.Exception.Message)")
            }
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

    , $errors.ToArray()
}
