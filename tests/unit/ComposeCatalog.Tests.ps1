# Invariants of $script:ComposeFileCatalog that Update-ComposeFileList relies on: it walks the catalog once, in order,
# so every file an entry names must come earlier, and an entry of an unknown Kind would never be emitted.
BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:KnownKinds = 'base', 'mode', 'provider', 'feature', 'overlay', 'optin', 'link', 'role', 'shared'
    $script:KnownRoles = '', 'services', 'platform'
}

Describe 'Compose file catalog' -Tag 'Unit' {
    It 'is not empty and starts with the base file' {
        $script:ComposeFileCatalog.Count | Should -BeGreaterThan 1
        $script:ComposeFileCatalog[0].Name | Should -BeExactly 'docker-compose.yml'
        $script:ComposeFileCatalog[0].Kind | Should -BeExactly 'base'
    }

    It 'has exactly one base and one mode entry' {
        @($script:ComposeFileCatalog | Where-Object { $_.Kind -ceq 'base' }) | Should -HaveCount 1
        @($script:ComposeFileCatalog | Where-Object { $_.Kind -ceq 'mode' }) | Should -HaveCount 1
    }

    It 'every Kind is one Update-ComposeFileList handles' {
        foreach ($entry in $script:ComposeFileCatalog) {
            $script:KnownKinds | Should -Contain $entry.Kind -Because "$($entry.Name) has Kind '$($entry.Kind)'"
            # -Contain is case-insensitive; the switch in Update-ComposeFileList is too, but the catalog spells them lowercase.
            $entry.Kind | Should -BeExactly $entry.Kind.ToLowerInvariant()
        }
    }

    It 'names are unique' {
        $names = @($script:ComposeFileCatalog | ForEach-Object { $_.Name })
        @($names | Sort-Object -Unique -CaseSensitive) | Should -HaveCount $names.Count
    }

    It 'Requires, Excludes and OverlayOf name entries that come earlier' {
        $earlier = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($entry in $script:ComposeFileCatalog) {
            foreach ($reference in @($entry.Requires) + @($entry.Excludes) + @($entry.OverlayOf | Where-Object { $_ })) {
                $earlier.Contains($reference) | Should -BeTrue -Because "$($entry.Name) names $reference, which must come earlier in the catalog"
            }
            $null = $earlier.Add($entry.Name)
        }
    }

    It 'an overlay names its file and is an .https.yml file; no other entry has OverlayOf' {
        foreach ($entry in $script:ComposeFileCatalog) {
            if ($entry.Kind -ceq 'overlay') {
                $entry.OverlayOf | Should -Not -BeNullOrEmpty -Because "$($entry.Name) is an overlay"
                $entry.Name | Should -BeExactly ($entry.OverlayOf -replace '\.yml$', '.https.yml')
            }
            else {
                $entry.OverlayOf | Should -BeNullOrEmpty -Because "$($entry.Name) is not an overlay"
            }
        }
    }

    It 'providers, features, opt-ins and shared markers have a Feature; other kinds do not' {
        foreach ($entry in $script:ComposeFileCatalog) {
            if ($entry.Kind -in 'provider', 'feature', 'optin', 'shared') {
                $entry.Feature | Should -Not -BeNullOrEmpty -Because "$($entry.Name) is a $($entry.Kind)"
            }
            else {
                $entry.Feature | Should -BeNullOrEmpty -Because "$($entry.Name) is a $($entry.Kind)"
            }
        }
    }

    It 'only links have Excludes or are Generated' {
        foreach ($entry in $script:ComposeFileCatalog | Where-Object { $_.Kind -cne 'link' }) {
            @($entry.Excludes) | Should -HaveCount 0 -Because "$($entry.Name) is a $($entry.Kind)"
            $entry.Generated | Should -BeFalse -Because "$($entry.Name) is a $($entry.Kind)"
        }
    }

    It 'every entry is emitted by some list: none is dead' {
        # Each role, each provider with every feature, opt-in and marker of the role, in HTTPS mode, with and without a
        # platform, with source modules, the generated files and a Compose that has the alias flag.
        $generated = @($script:ComposeFileCatalog | Where-Object { $_.Generated } | ForEach-Object { $_.Name })
        $platform = Get-ComposeFileName 'platform.yml'
        $emitted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($role in $script:KnownRoles) {
            $everyFeature = @($script:ComposeFileCatalog |
                    Where-Object { $_.Kind -in 'mode', 'feature', 'optin' -and $_.Roles -ccontains $role } | ForEach-Object { $_.Name })
            $providers = @($script:ComposeFileCatalog |
                    Where-Object { $_.Kind -in 'provider', 'shared' -and $_.Feature -in $script:DbProviders -and $_.Roles -ccontains $role })
            $markers = @($script:ComposeFileCatalog |
                    Where-Object { $_.Kind -ceq 'shared' -and $_.Feature -notin $script:DbProviders -and $_.Roles -ccontains $role } | ForEach-Object { $_.Name })
            foreach ($provider in $providers) {
                foreach ($features in @($everyFeature), @($everyFeature | Where-Object { $_ -cne $platform })) {
                    [string[]]$list = Update-ComposeFileList -ComposeFiles (@($features) + $markers + $provider.Name) -HasSourceModules $true `
                        -Role $role -GeneratedFiles $generated -ComposeVersion '5.7.0' -WarningAction SilentlyContinue
                    foreach ($name in $list) {
                        $null = $emitted.Add($name)
                    }
                }
            }
        }
        foreach ($entry in $script:ComposeFileCatalog) {
            $emitted.Contains($entry.Name) | Should -BeTrue -Because "no list emits $($entry.Name)"
        }
    }

    It 'every entry names the roles it may be emitted in' {
        foreach ($entry in $script:ComposeFileCatalog) {
            @($entry.Roles).Count | Should -BeGreaterThan 0 -Because "$($entry.Name) has no Roles"
            foreach ($role in $entry.Roles) {
                $script:KnownRoles | Should -Contain $role -Because "$($entry.Name) names the role '$role'"
            }
        }
        foreach ($entry in $script:ComposeFileCatalog | Where-Object { $_.Kind -in 'base', 'mode' }) {
            @($entry.Roles) | Should -Be $script:KnownRoles -Because "$($entry.Name) is in every role"
        }
    }

    It 'an entry''s roles are roles of every file it requires or overlays' {
        $byName = @{}
        foreach ($entry in $script:ComposeFileCatalog) {
            foreach ($reference in @($entry.Requires) + @($entry.OverlayOf | Where-Object { $_ })) {
                foreach ($role in $entry.Roles) {
                    $byName[$reference].Roles | Should -Contain $role -Because "$($entry.Name) is emitted in '$role', but $reference is not"
                }
            }
            $byName[$entry.Name] = $entry
        }
    }

    It 'a role entry is the network of its role only; a shared marker needs the shared network' {
        @($script:ComposeFileCatalog | Where-Object { $_.Kind -ceq 'role' } | ForEach-Object { $_.Name }) |
            Should -Be @('docker-compose/services-network.yml', 'docker-compose/shared-network.yml')
        foreach ($entry in $script:ComposeFileCatalog | Where-Object { $_.Kind -ceq 'shared' }) {
            $entry.Requires | Should -Contain 'docker-compose/shared-network.yml'
            @($entry.Roles) | Should -Be @('platform')
        }
    }

    It 'only the alias file has a MinComposeVersion, 5.7.0, and it requires platform-shared' {
        $versioned = @($script:ComposeFileCatalog | Where-Object { $_.MinComposeVersion })
        $versioned | Should -HaveCount 1
        $versioned[0].Name | Should -BeExactly 'docker-compose/platform-shared-alias.yml'
        $versioned[0].MinComposeVersion | Should -BeExactly '5.7.0'
        $versioned[0].Requires | Should -Contain 'docker-compose/platform-shared.yml'
    }

    It 'Update-ComposeFileList keeps the catalog order whatever the input order' {
        $catalogOrder = @($script:ComposeFileCatalog | ForEach-Object { $_.Name })
        [string[]]$requested = Get-DefaultComposeFiles -Provider 'mysql' -Https $true
        [array]::Reverse($requested)

        [string[]]$result = Update-ComposeFileList -ComposeFiles $requested -HasSourceModules $false

        $positions = @($result | ForEach-Object { $catalogOrder.IndexOf($_) })
        $positions | Should -Not -Contain -1
        $positions | Should -Be @($positions | Sort-Object)
    }
}
