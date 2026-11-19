BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

Describe 'Compose helper' -Tag 'Unit' {
    Context 'Get-ComposeVersion' {
        AfterEach {
            # Get-ComposeVersion remembers a plugin that answered; no later test may inherit that.
            $script:DockerComposeAvailable = $false
        }

        It 'returns the version alone when the Docker CLI also writes a warning to stderr' {
            function docker {
                Write-Error -Message 'WARNING: Error loading config file: /home/u/.docker/config.json: permission denied' -ErrorAction Continue
                '2.40.3'
                $global:LASTEXITCODE = 0
            }

            Get-ComposeVersion | Should -BeExactly '2.40.3'
        }

        It 'throws with Docker''s message when the plugin fails' {
            function docker { Write-Error -Message "docker: 'compose' is not a docker command." -ErrorAction Continue; $global:LASTEXITCODE = 1 }

            { Get-ComposeVersion } | Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage "*'compose' is not a docker command*"
        }
    }

    Context 'Test-ComposeVersion' {
        It 'accepts <Version> against the default minimum: <Expected>' -TestCases @(
            @{ Version = '2.18.0'; Expected = $true }
            @{ Version = '2.17.3'; Expected = $false }
            @{ Version = 'v2.40.3'; Expected = $true }
            @{ Version = '5.6.0'; Expected = $true }
            @{ Version = '2.18.0-desktop.1'; Expected = $true }
        ) {
            Test-ComposeVersion -Version $Version | Should -Be $Expected
        }

        It 'takes the minimum from -Minimum' {
            Test-ComposeVersion '2.20.0' '2.21.0' | Should -BeFalse
            Test-ComposeVersion '2.21.0' '2.21.0' | Should -BeTrue
        }

        It 'compares numbers, not text (2.100.0 is newer than 2.18.0)' {
            Test-ComposeVersion '2.100.0' | Should -BeTrue
        }

        It 'treats text that is not a version as too old' {
            Test-ComposeVersion 'not-a-version' | Should -BeFalse
            Test-ComposeVersion '' | Should -BeFalse
        }
    }
}
