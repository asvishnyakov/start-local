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

    Context 'Get-ComposeVersionOrEmpty' {
        AfterEach {
            $script:DockerComposeAvailable = $false
        }

        It 'returns the version when Compose answers' {
            function docker { '2.40.3'; $global:LASTEXITCODE = 0 }

            Get-ComposeVersionOrEmpty | Should -BeExactly '2.40.3'
        }

        It 'returns an empty string, and does not throw, when docker compose version fails' {
            function docker { Write-Error -Message "docker: 'compose' is not a docker command." -ErrorAction Continue; $global:LASTEXITCODE = 1 }

            Get-ComposeVersionOrEmpty | Should -BeExactly ''
        }

        It 'returns an empty string, and does not throw, when there is no docker command' {
            $originalPath = $env:PATH
            try {
                $env:PATH = $TestDrive
                Get-Command docker -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the test needs a session without docker'

                Get-ComposeVersionOrEmpty | Should -BeExactly ''
            }
            finally {
                $env:PATH = $originalPath
            }
        }

        It 'lets an unexpected exception propagate' {
            function docker { throw [System.ArgumentException]::new('unexpected') }

            { Get-ComposeVersionOrEmpty } | Should -Throw -ExceptionType ([System.ArgumentException])
        }
    }

    Context 'Test-ComposeVersion' {
        It 'accepts <Version> against the default minimum: <Expected>' -TestCases @(
            @{ Version = '2.24.6'; Expected = $true }
            @{ Version = '2.24.5'; Expected = $false }
            @{ Version = '2.18.0'; Expected = $false }
            @{ Version = 'v2.40.3'; Expected = $true }
            @{ Version = '5.6.0'; Expected = $true }
            @{ Version = '2.24.6-desktop.1'; Expected = $true }
        ) {
            Test-ComposeVersion -Version $Version | Should -Be $Expected
        }

        It 'takes the minimum from -Minimum' {
            Test-ComposeVersion '2.20.0' '2.21.0' | Should -BeFalse
            Test-ComposeVersion '2.21.0' '2.21.0' | Should -BeTrue
        }

        It 'compares numbers, not text (2.100.0 is newer than 2.24.6)' {
            Test-ComposeVersion '2.100.0' | Should -BeTrue
        }

        It 'treats text that is not a version as too old' {
            Test-ComposeVersion 'not-a-version' | Should -BeFalse
            Test-ComposeVersion '' | Should -BeFalse
        }
    }
}
