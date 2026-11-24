# Migration of a solution folder from layout 1 (DB_PROVIDER, fixed volume and image names) to layout 2
# (COMPOSE_FILE, VOLUME_PREFIX, per-project image tags). Keyed on START_LOCAL_LAYOUT; a missing key means layout 1,
# unless the file sets COMPOSE_FILE or STACK_ROLE and no DB_PROVIDER (R35, see Get-EnvLayout).
# build, start and stop run Invoke-StartLocalMigration first; remove runs it after its read-only guards (.git, .env,
# Compose); the installer checks that the migration would succeed before it copies the payload, and migrates after the
# copy. It is idempotent and changes only .env and the name of the last 1.x build's package manifest; the installer
# rebuilds the images after a migration.

# Keys layout 2 no longer reads (C6); DB_PROVIDER goes after it has been turned into COMPOSE_FILE.
$script:LayoutOneRemovedKeys = 'DB_PROVIDER', 'ES_CLUSTER_NAME', 'ES_LICENSE'

function Get-EnvLayout {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory, Position = 0)][psobject]$Document)

    $value = Get-EnvValue -Document $Document -Key 'START_LOCAL_LAYOUT'
    if ([string]::IsNullOrWhiteSpace($value)) {
        # R35: a file written beforehand (a cloud wrapper) has COMPOSE_FILE and no DB_PROVIDER; layout 1 always has DB_PROVIDER.
        $hasComposeFile = -not [string]::IsNullOrWhiteSpace((Get-EnvValue -Document $Document -Key 'COMPOSE_FILE'))
        $hasProvider = -not [string]::IsNullOrWhiteSpace((Get-EnvValue -Document $Document -Key 'DB_PROVIDER'))
        # A services or platform .env starts with an empty COMPOSE_FILE (the installer fills it); layout 1 has no STACK_ROLE.
        $hasStackRole = -not [string]::IsNullOrWhiteSpace((Get-EnvValue -Document $Document -Key 'STACK_ROLE'))
        return $(if (($hasComposeFile -or $hasStackRole) -and -not $hasProvider) { 2 } else { 1 })
    }
    $layout = 0
    if (-not [int]::TryParse($value, [ref]$layout)) {
        throw [System.InvalidOperationException]::new("START_LOCAL_LAYOUT in .env is '$value'; expected a number.")
    }
    $layout
}

function Convert-EnvToLayout2 {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][psobject]$Template
    )

    $changes = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $result = { [pscustomobject]@{ Document = $Document; Changes = [string[]]$changes.ToArray(); Notes = [string[]]$notes.ToArray() } }

    if ((Get-EnvLayout -Document $Document) -ge 2) {
        return & $result
    }

    # Validate before the first change, so a failed migration leaves the document as it was.
    # 1.x trimmed and lower-cased DB_PROVIDER (start-VC-solution.ps1), so any case of a known provider is a working folder.
    $providerValue = [string](Get-EnvValue -Document $Document -Key 'DB_PROVIDER')
    $provider = $providerValue.Trim().ToLowerInvariant()
    if ($script:DbProviders -cnotcontains $provider) {
        $shown = if ([string]::IsNullOrWhiteSpace($providerValue)) { 'missing' } else { "'$providerValue'" }
        throw [System.InvalidOperationException]::new(
            "DB_PROVIDER in .env is $shown; expected one of: $($script:DbProviders -join ', '). Fix it and run the script again.")
    }

    # Template keys first, so the migrated keys sit where .env.example puts them; the steps below then set their values.
    # Layout 1 meant ${STACK_VERSION:-8.18.0}; the template's newer version would open 8.x data with Elasticsearch 9.
    if ([string]::IsNullOrWhiteSpace((Get-EnvValue -Document $Document -Key 'STACK_VERSION'))) {
        Set-EnvValue -Document $Document -Key 'STACK_VERSION' -Value '8.18.0'
        $changes.Add('Set STACK_VERSION=8.18.0 (the 1.x default)')
    }
    foreach ($key in (Add-MissingEnvKeys -Document $Document -Template $Template)) {
        $changes.Add("Added $key")
    }

    $composeFile = ConvertTo-ComposeFileValue (Get-DefaultComposeFiles -Provider $provider -Https $false)
    Set-EnvValue -Document $Document -Key 'COMPOSE_FILE' -Value $composeFile
    $changes.Add("Set COMPOSE_FILE=$composeFile (from DB_PROVIDER=$providerValue)")

    if ((Get-EnvValue -Document $Document -Key 'COMPOSE_PATH_SEPARATOR') -cne ';') {
        Set-EnvValue -Document $Document -Key 'COMPOSE_PATH_SEPARATOR' -Value ';'
        $changes.Add('Set COMPOSE_PATH_SEPARATOR=;')
    }
    if ([string]::IsNullOrEmpty((Get-EnvValue -Document $Document -Key 'VOLUME_PREFIX'))) {
        # Existing volumes keep their virto_* names (D3).
        Set-EnvValue -Document $Document -Key 'VOLUME_PREFIX' -Value 'virto'
        $changes.Add('Set VOLUME_PREFIX=virto')
    }

    foreach ($key in $script:LayoutOneRemovedKeys) {
        if (Remove-EnvKey -Document $Document -Key $key) {
            $changes.Add("Removed $key")
        }
    }

    Set-EnvValue -Document $Document -Key 'START_LOCAL_LAYOUT' -Value '2'
    $changes.Add('Set START_LOCAL_LAYOUT=2')

    $notes.Add('This folder keeps running in HTTP mode, so its URLs stay the same.')
    $notes.Add("Published ports now bind to $(Get-EnvValue -Document $Document -Key 'BIND_ADDRESS') only. To reach the stack from other machines again, set BIND_ADDRESS=0.0.0.0 in .env.")
    $notes.Add('Redis is now a cache without a volume. The old virto_redisdata volume is left alone; a full remove deletes it.')
    $notes.Add('The platform modules now come from the image, so they match the rebuilt platform. The old virto_modules-data volume is left alone; a full remove deletes it.')

    & $result
}

function Rename-LayoutOnePackageManifest {
    # Gives the package manifest of the last 1.x build its layout-2 name, vc-package.json, so the first build after the
    # migration compares with it: the database is migrated up to its versions. 1.x installed stable from
    # backend/stable-packages.json, custom from backend/custom-packages.json, and edge, when run from the folder, from
    # vc-package.json; vc-build rewrites the manifest it installs from, so the newest is the last build's. Returns the
    # change, or $null when there is nothing to rename.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$SolutionFolder)

    $manifestPath = Get-PackageManifestPath -SolutionFolder $SolutionFolder
    $newest = @($manifestPath, (Join-Path $SolutionFolder 'backend/stable-packages.json'), (Join-Path $SolutionFolder 'backend/custom-packages.json') |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Get-Item | Sort-Object LastWriteTimeUtc -Descending) | Select-Object -First 1
    if (-not $newest -or $newest.FullName -eq [System.IO.Path]::GetFullPath($manifestPath)) {
        return $null
    }
    Move-Item -LiteralPath $newest.FullName -Destination $manifestPath -Force
    $relativePath = [System.IO.Path]::GetRelativePath($SolutionFolder, $newest.FullName) -replace '\\', '/'
    "Renamed $relativePath to vc-package.json (the manifest of the last 1.x build)"
}

function Invoke-StartLocalMigration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, Position = 0)][string]$SolutionFolder)

    $envPath = Join-Path $SolutionFolder '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        return $null
    }

    $templatePath = Join-Path $SolutionFolder '.env.example'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        $templatePath = Join-Path $PSScriptRoot '../.env.example'
    }
    $migration = Convert-EnvToLayout2 -Document (Read-EnvFile -Path $envPath) -Template (Read-EnvFile -Path $templatePath)

    # The layout-1 images are not reused: they cannot run under the layout-2 compose files (other ports, no health-check
    # tool in the storefront image), so the installer rebuilds after a migration.
    $changes = $migration.Changes
    if ($changes.Count -gt 0) {
        Write-EnvFile -Document $migration.Document -Path $envPath
        $renamed = Rename-LayoutOnePackageManifest $SolutionFolder
        if ($renamed) {
            $changes = [string[]]@($changes + $renamed)
        }

        Write-Host 'Migrated .env to layout 2:'
        foreach ($change in $changes) { Write-Host "  $change" }
        foreach ($note in $migration.Notes) { Write-Host $note }
    }

    [pscustomobject]@{
        Changes = $changes
        Notes   = $migration.Notes
    }
}
