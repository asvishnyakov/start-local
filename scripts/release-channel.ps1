# Release channels: parsing RELEASE_CHANNEL and turning it into vc-build arguments and a bundle spec.
#
# Channel: [pscustomobject]@{ Kind; Number; Normalized; Warnings }
#   Kind        stable | stable-n | edge | custom
#   Number      the N of 'stable:<N>'; else $null
#   Normalized  the canonical value to write back to .env ('stable', 'stable:16', 'edge', 'custom')
#   Warnings    string[] of notes for the user (for example the rename of 'latest-stable')
#
# The channel names follow Virto Commerce's release channels and vc-build's switches: stable is the absence
# of -Edge, '-v <N>' picks Stable N. The numbers have gaps, and vc-build crashes on an unknown key, so
# '<N>' is checked against the keys of bundles/stable.json first.

$script:StableJsonUrl = 'https://raw.githubusercontent.com/VirtoCommerce/vc-modules/refs/heads/master/bundles/stable.json'
$script:LatestFrontendReleaseApiUrl = 'https://api.github.com/repos/VirtoCommerce/vc-frontend/releases/latest'

function ConvertTo-ReleaseChannel {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Value
    )

    $text = if ($null -eq $Value) { '' } else { $Value.Trim().ToLowerInvariant() }
    $warnings = [string[]]@()
    $kind = $null
    $number = $null

    $stableNumber = [regex]::Match($text, '^stable:(?<number>\d+)$')
    switch -Regex ($text) {
        '^stable$' { $kind = 'stable' }
        '^latest-stable$' {
            $kind = 'stable'
            $warnings = [string[]]@("Release channel 'latest-stable' was renamed to 'stable'; using 'stable'.")
        }
        '^edge$' { $kind = 'edge' }
        '^custom$' { $kind = 'custom' }
        default {
            $parsed = 0
            if ($stableNumber.Success -and [int]::TryParse($stableNumber.Groups['number'].Value, [ref]$parsed)) {
                $kind = 'stable-n'
                $number = $parsed
            }
        }
    }
    if (-not $kind) {
        return $null
    }

    [pscustomobject]@{
        Kind       = $kind
        Number     = $number
        Normalized = if ($kind -eq 'stable-n') { "stable:$number" } else { $kind }
        Warnings   = $warnings
    }
}

function Test-StableBundleKey {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][int]$Number,
        [Parameter(Mandatory, Position = 1)][psobject]$StableJson
    )

    # The lookup in vc-build is an exact match on the key: '16' works, 'v16' does not.
    $StableJson.PSObject.Properties.Name -ccontains "$Number"
}

function Get-BundleSpec {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Channel
    )

    switch ($Channel.Kind) {
        'stable' { $bundleKey = 'latest'; $frontendSource = 'bundle' }
        'stable-n' { $bundleKey = "$($Channel.Number)"; $frontendSource = 'bundle' }
        'edge' { $bundleKey = $null; $frontendSource = 'latest-release' }
        'custom' { $bundleKey = $null; $frontendSource = 'custom' }
        default { throw [System.ArgumentException]::new("Unknown release channel kind '$($Channel.Kind)'.", 'Channel') }
    }

    [pscustomobject]@{
        BundleKey      = $bundleKey
        FrontendSource = $frontendSource
    }
}

function Get-VcBuildInstallArgs {
    # vc-build's arguments for the channel. -Update: a later build of stable or edge, whose vc-package.json exists:
    # install would reuse it unchanged, so update first moves the platform and the modules it lists to the channel's
    # versions (it adds none: the module set stays the installed one), and install then installs from it. The update only rewrites the manifest (its install targets skipped), so a downgrade can be refused before
    # anything is installed. It also skips ShowDiff, which asks for confirmation on a local build and, with no answer,
    # exits 0 without updating.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Channel,
        [Parameter(Mandatory, Position = 1)][string]$ManifestPath,
        [Parameter(Mandatory, Position = 2)][string]$DiscoveryPath,
        [Parameter(Mandatory, Position = 3)][string]$ProbingPath,
        [Parameter(Mandatory, Position = 4)][string]$Root,
        [switch]$Update
    )

    if ($Update -and $Channel.Kind -eq 'custom') {
        throw [System.ArgumentException]::new('The custom channel installs from the manifest as given; it is never updated.', 'Update')
    }
    $verb = if ($Update) { 'update' } else { 'install' }
    # @() keeps a one-item result an array, so the '+' below appends instead of concatenating strings.
    $head = @(switch ($Channel.Kind) {
        'stable' { @($verb) }
        'stable-n' { @($verb, '-v', "$($Channel.Number)") }
        'edge' { @($verb, '-Edge') }
        'custom' { @('install', '--package-manifest-path', $ManifestPath) }
        default { throw [System.ArgumentException]::new("Unknown release channel kind '$($Channel.Kind)'.", 'Channel') }
    })
    $tail = '--probing-path', $ProbingPath, '--discovery-path', $DiscoveryPath, '--root', $Root, '--skip-dependency-solving'
    if ($Update) {
        $tail += '--skip', 'ShowDiff', 'InstallPlatform', 'InstallModules', 'ValidateDependencies'
    }

    # The unary comma keeps the array intact through the pipeline.
    , [string[]]@($head + $tail)
}

function Get-PackageManifestPath {
    # The package manifest vc-build installs from and writes back, on every channel: vc-package.json, which vc-build keeps
    # in the folder it runs in (build.ps1 runs it in the solution folder), and which a custom build copies
    # CUSTOM_PACKAGES_JSON into. It lists the platform and the modules of the last build's image, so start compares the
    # installed modules with it, and the next build, on any channel, refuses to go below it.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$SolutionFolder)

    Join-Path $SolutionFolder 'vc-package.json'
}

function Read-PackageManifest {
    # A vc-package.json as @{ PlatformVersion; Modules } (Modules: id -> version, over every source), or $null when the
    # file does not exist.
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    ConvertFrom-PackageManifestJson (Get-Content -LiteralPath $Path -Raw)
}

function ConvertFrom-PackageManifestJson {
    # The text of a vc-package.json as Read-PackageManifest returns it.
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory, Position = 0)][string]$Json)

    $manifest = $Json | ConvertFrom-Json
    $modules = [ordered]@{}
    foreach ($module in @($manifest.Sources | ForEach-Object { $_.Modules }) | Where-Object { $_.Id } | Sort-Object Id) {
        $modules[[string]$module.Id] = [string]$module.Version
    }
    [pscustomobject]@{ PlatformVersion = [string]$manifest.PlatformVersion; Modules = $modules }
}

function Restore-PackageManifest {
    # Puts back the manifest a build started with: its -Content, or no file when the build started without one.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][byte[]]$Content
    )

    if ($null -eq $Content) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Ignore
        return
    }
    [System.IO.File]::WriteAllBytes($Path, $Content)
}

function Get-PackageManifestDowngrades {
    # "<name> <from> -> <to>" for the platform and each module whose version is lower in -After than in -Before. Added
    # and removed modules, and versions that are not semantic versions, are not compared.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][psobject]$Before,
        [Parameter(Mandatory)][psobject]$After
    )

    $pairs = @(@{ Name = 'the platform'; From = $Before.PlatformVersion; To = $After.PlatformVersion }) +
        @(foreach ($id in $After.Modules.Keys) {
                if ($Before.Modules.Contains($id)) {
                    @{ Name = $id; From = $Before.Modules[$id]; To = $After.Modules[$id] }
                }
            })
    foreach ($pair in $pairs) {
        $from = $null
        $to = $null
        if ([System.Management.Automation.SemanticVersion]::TryParse($pair.From, [ref]$from) -and
            [System.Management.Automation.SemanticVersion]::TryParse($pair.To, [ref]$to) -and $to -lt $from) {
            "$($pair.Name) $($pair.From) -> $($pair.To)"
        }
    }
}

function ConvertFrom-JsonResponse {
    param($Response)

    # raw.githubusercontent.com serves text/plain, so Invoke-RestMethod may hand back the raw text.
    if ($Response -is [string]) {
        return $Response | ConvertFrom-Json
    }
    $Response
}

function Invoke-JsonDownload {
    # Invoke-RestMethod that names what it downloads and from where when it fails.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Uri,
        [Parameter(Mandatory, Position = 1)][string]$What
    )

    try {
        ConvertFrom-JsonResponse (Invoke-RestMethod -Uri $Uri)
    }
    catch {
        throw [System.InvalidOperationException]::new("Could not download $What from $Uri : $($_.Exception.Message)", $_.Exception)
    }
}

function Invoke-FileDownload {
    # Invoke-WebRequest -OutFile that names what it downloads and from where when it fails.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Uri,
        [Parameter(Mandatory, Position = 1)][string]$OutFile,
        [Parameter(Mandatory, Position = 2)][string]$What
    )

    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile
    }
    catch {
        throw [System.InvalidOperationException]::new("Could not download $What from $Uri : $($_.Exception.Message)", $_.Exception)
    }
}

function Get-StableJson {
    [CmdletBinding()]
    [OutputType([psobject])]
    param()

    Invoke-JsonDownload $script:StableJsonUrl 'the stable bundle list'
}

function Get-BundleFrontendUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$BundleKey,
        [Parameter(Mandatory, Position = 1)][psobject]$StableJson
    )

    $property = $StableJson.PSObject.Properties[$BundleKey]
    if (-not $property) {
        throw [System.ArgumentException]::new("Bundle '$BundleKey' is not listed in bundles/stable.json.", 'BundleKey')
    }

    $packages = Invoke-JsonDownload $property.Value "the package list of bundle '$BundleKey'"
    $frontendUrl = $packages.ThemeB2BVue
    if ([string]::IsNullOrWhiteSpace($frontendUrl)) {
        throw [System.InvalidOperationException]::new("Bundle '$BundleKey' has no ThemeB2BVue entry in its package.json.")
    }
    $frontendUrl
}

function Get-LatestFrontendReleaseUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $release = Invoke-JsonDownload $script:LatestFrontendReleaseApiUrl 'the latest vc-frontend release'
    $asset = @($release.assets | Where-Object { $_.name -like '*.zip' }) | Select-Object -First 1
    if (-not $asset) {
        throw [System.InvalidOperationException]::new('The latest vc-frontend release has no .zip asset.')
    }
    $asset.browser_download_url
}
