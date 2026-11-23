BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:StableJson = Get-Content -Raw -Path "$PSScriptRoot/../fixtures/json/stable.json" | ConvertFrom-Json
}

Describe 'ReleaseChannel' -Tag 'Unit' {
    Context 'ConvertTo-ReleaseChannel' {
        It 'parses <Value>' -TestCases @(
            @{ Value = 'stable'; Kind = 'stable'; Number = $null; Normalized = 'stable' }
            @{ Value = 'stable:16'; Kind = 'stable-n'; Number = 16; Normalized = 'stable:16' }
            @{ Value = 'edge'; Kind = 'edge'; Number = $null; Normalized = 'edge' }
            @{ Value = 'custom'; Kind = 'custom'; Number = $null; Normalized = 'custom' }
        ) {
            $channel = ConvertTo-ReleaseChannel -Value $Value
            $channel.Kind | Should -Be $Kind
            $channel.Number | Should -Be $Number
            $channel.Normalized | Should -Be $Normalized
            @($channel.Warnings) | Should -HaveCount 0
        }

        It 'accepts latest-stable as stable with a rename warning' {
            $channel = ConvertTo-ReleaseChannel -Value 'latest-stable'
            $channel.Kind | Should -Be 'stable'
            $channel.Normalized | Should -Be 'stable'
            @($channel.Warnings) | Should -HaveCount 1
            $channel.Warnings[0] | Should -Match "renamed to 'stable'"
        }

        It 'rejects <Name>' -TestCases @(
            @{ Name = 'an unknown name'; Value = 'foo' }
            @{ Name = 'a missing number'; Value = 'stable:' }
            @{ Name = 'a non-numeric number'; Value = 'stable:x' }
            @{ Name = 'a negative number'; Value = 'stable:-1' }
            @{ Name = 'a number out of range'; Value = 'stable:99999999999' }
            @{ Name = 'an empty string'; Value = '' }
        ) {
            ConvertTo-ReleaseChannel -Value $Value | Should -BeNullOrEmpty
        }
    }

    Context 'Test-StableBundleKey' {
        It 'is <Expected> for <Number>' -TestCases @(
            @{ Number = 13; Expected = $false }
            @{ Number = 16; Expected = $true }
            @{ Number = 0; Expected = $true }
            @{ Number = 17; Expected = $false }
        ) {
            Test-StableBundleKey -Number $Number -StableJson $script:StableJson | Should -Be $Expected
        }
    }

    Context 'Get-VcBuildInstallArgs' {
        It 'builds the arguments for <Value>' -TestCases @(
            @{ Value = 'stable'; Head = @('install') }
            @{ Value = 'stable:16'; Head = @('install', '-v', '16') }
            @{ Value = 'edge'; Head = @('install', '-Edge') }
            @{ Value = 'custom'; Head = @('install', '--package-manifest-path', 'M') }
        ) {
            $channel = ConvertTo-ReleaseChannel -Value $Value
            $actual = Get-VcBuildInstallArgs -Channel $channel -ManifestPath 'M' -DiscoveryPath 'D' -ProbingPath 'P' -Root 'R'
            $tail = '--probing-path', 'P', '--discovery-path', 'D', '--root', 'R', '--skip-dependency-solving'
            $actual | Should -BeOfType [string]
            $actual | Should -Be ([string[]](@($Head) + $tail))
        }

        # A later build moves the existing vc-package.json to the channel's bundle: install would reuse it unchanged.
        # update asks for confirmation on a local build (ShowDiff), and with no answer it exits 0 without updating.
        It 'builds the update arguments for <Value>' -TestCases @(
            @{ Value = 'stable'; Head = @('update') }
            @{ Value = 'stable:16'; Head = @('update', '-v', '16') }
            @{ Value = 'edge'; Head = @('update', '-Edge') }
        ) {
            $channel = ConvertTo-ReleaseChannel -Value $Value
            $actual = Get-VcBuildInstallArgs -Channel $channel -ManifestPath 'M' -DiscoveryPath 'D' -ProbingPath 'P' -Root 'R' -Update
            $tail = '--probing-path', 'P', '--discovery-path', 'D', '--root', 'R', '--skip-dependency-solving', '--skip', 'ShowDiff', 'InstallPlatform', 'InstallModules', 'ValidateDependencies'
            $actual | Should -Be ([string[]](@($Head) + $tail))
        }

        It 'refuses -Update for the custom channel, whose manifest is the user''s' {
            { Get-VcBuildInstallArgs -Channel (ConvertTo-ReleaseChannel -Value 'custom') -ManifestPath 'M' -DiscoveryPath 'D' -ProbingPath 'P' -Root 'R' -Update } |
                Should -Throw -ExceptionType ([System.ArgumentException])
        }
    }

    Context 'package manifests' {
        BeforeAll {
            function script:New-PackageManifest {
                param([string]$Platform, [hashtable]$Modules)
                $path = Join-Path $TestDrive "vc-package-$([guid]::NewGuid().ToString('N')).json"
                $moduleItems = @($Modules.Keys | Sort-Object | ForEach-Object { @{ Id = $_; Version = $Modules[$_] } })
                @{ ManifestVersion = '2.0'; PlatformVersion = $Platform; Sources = @(@{ Name = 'GithubReleases'; Modules = $moduleItems }) } |
                    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
                $path
            }
        }

        It 'puts the manifest of <Value> at <Expected>' -TestCases @(
            @{ Value = 'stable'; Expected = 'vc-package.json' }
            @{ Value = 'edge'; Expected = 'vc-package.json' }
            @{ Value = 'custom'; Expected = 'backend/custom-packages.json' }
        ) {
            Get-PackageManifestPath -SolutionFolder '/solution' -Channel (ConvertTo-ReleaseChannel -Value $Value) |
                Should -Be (Join-Path '/solution' $Expected)
        }

        It 'reads the platform version and the modules of every source' {
            $path = New-PackageManifest -Platform '3.1039.2' -Modules @{ 'Vendor.B' = '3.2.0'; 'Vendor.A' = '3.1.0' }
            $manifest = Read-PackageManifest $path
            $manifest.PlatformVersion | Should -Be '3.1039.2'
            @($manifest.Modules.Keys) | Should -Be @('Vendor.A', 'Vendor.B')
            $manifest.Modules['Vendor.B'] | Should -Be '3.2.0'
        }

        It 'is $null for a manifest that does not exist' {
            Read-PackageManifest (Join-Path $TestDrive 'nowhere.json') | Should -BeNullOrEmpty
        }

        It 'names every lower platform or module version, and ignores added, removed and unparsable ones' {
            $before = Read-PackageManifest (New-PackageManifest -Platform '3.1076.0' -Modules @{ 'Vendor.A' = '3.10.0'; 'Vendor.B' = '3.2.0'; 'Vendor.Gone' = '1.0.0'; 'Vendor.Odd' = 'latest' })
            $after = Read-PackageManifest (New-PackageManifest -Platform '3.1039.2' -Modules @{ 'Vendor.A' = '3.9.0'; 'Vendor.B' = '3.3.0'; 'Vendor.New' = '1.0.0'; 'Vendor.Odd' = '1.0.0' })

            Get-PackageManifestDowngrades -Before $before -After $after |
                Should -Be @('the platform 3.1076.0 -> 3.1039.2', 'Vendor.A 3.10.0 -> 3.9.0')
        }

        It 'finds no downgrade between equal or higher versions' {
            $before = Read-PackageManifest (New-PackageManifest -Platform '3.1039.2' -Modules @{ 'Vendor.A' = '3.1.0-alpha.1' })
            $after = Read-PackageManifest (New-PackageManifest -Platform '3.1039.2' -Modules @{ 'Vendor.A' = '3.1.0' })
            @(Get-PackageManifestDowngrades -Before $before -After $after) | Should -HaveCount 0
        }
    }

    Context 'Get-BundleSpec' {
        It 'resolves <Value>' -TestCases @(
            @{ Value = 'stable'; BundleKey = 'latest'; FrontendSource = 'bundle' }
            @{ Value = 'stable:16'; BundleKey = '16'; FrontendSource = 'bundle' }
            @{ Value = 'edge'; BundleKey = $null; FrontendSource = 'latest-release' }
            @{ Value = 'custom'; BundleKey = $null; FrontendSource = 'custom' }
        ) {
            $spec = Get-BundleSpec -Channel (ConvertTo-ReleaseChannel -Value $Value)
            $spec.BundleKey | Should -Be $BundleKey
            $spec.FrontendSource | Should -Be $FrontendSource
        }
    }
}
