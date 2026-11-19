# Invariants of $script:ComposeFileCatalog that Update-ComposeFileList relies on: it walks the catalog once, in order,
# so every file an entry names must come earlier, and an entry of an unknown Kind would never be emitted.
BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:KnownKinds = 'base', 'mode', 'provider', 'feature', 'overlay', 'optin', 'link'
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

    It 'providers, features and opt-ins have a Feature; other kinds do not' {
        foreach ($entry in $script:ComposeFileCatalog) {
            if ($entry.Kind -in 'provider', 'feature', 'optin') {
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
        # Each provider with every feature and opt-in, in HTTPS mode, with and without a platform, with source modules.
        $everyFeature = @($script:ComposeFileCatalog | Where-Object { $_.Kind -in 'mode', 'feature', 'optin' } | ForEach-Object { $_.Name })
        $platform = Get-ComposeFileName 'platform.yml'
        $emitted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($provider in $script:ComposeFileCatalog | Where-Object { $_.Kind -ceq 'provider' }) {
            foreach ($features in @($everyFeature), @($everyFeature | Where-Object { $_ -cne $platform })) {
                [string[]]$list = Update-ComposeFileList -ComposeFiles (@($features) + $provider.Name) -HasSourceModules $true
                foreach ($name in $list) {
                    $null = $emitted.Add($name)
                }
            }
        }
        foreach ($entry in $script:ComposeFileCatalog) {
            $emitted.Contains($entry.Name) | Should -BeTrue -Because "no list emits $($entry.Name)"
        }
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
