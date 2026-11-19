BeforeAll {
    # The bootstrap functions sit above install.ps1's dot-source guard, so loading it runs nothing.
    . "$PSScriptRoot/../../install.ps1"
}

Describe 'Bootstrap' -Tag 'Unit' {
    Context 'Resolve-ReleaseRef' {
        It 'skips the API when a branch is given' {
            Mock Invoke-RestMethod { throw 'the API must not be called' }

            $result = Resolve-ReleaseRef -Branch 'release/1.0'

            $result.Ref | Should -BeExactly 'release/1.0'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'resolves the latest release tag when no branch is given' {
            Mock Invoke-RestMethod { @{ tag_name = 'v2.0.0' } }

            $result = Resolve-ReleaseRef

            $result.Ref | Should -BeExactly 'v2.0.0'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://api.github.com/repos/VirtoCommerce/start-local/releases/latest'
            }
        }

        It 'fails with a hint about -branch when the API call fails' {
            Mock Invoke-RestMethod { throw 'rate limit exceeded' }

            { Resolve-ReleaseRef } | Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*-branch*'
        }

        It 'fails when the release has no tag name' {
            Mock Invoke-RestMethod { @{ name = 'untagged' } }

            { Resolve-ReleaseRef } | Should -Throw -ExceptionType ([System.InvalidOperationException])
        }
    }

    Context 'Get-PayloadZipUrl' {
        # GitHub's archive/<ref>.zip serves a branch (slash included) or a tag, so -branch takes either (README).
        It 'points a ref at archive/<ref>.zip (<Ref>)' -ForEach @(
            @{ Ref = 'release/1.0' }
            @{ Ref = 'v2.0.0' }
        ) {
            Get-PayloadZipUrl -Ref $Ref | Should -BeExactly "https://github.com/VirtoCommerce/start-local/archive/$Ref.zip"
        }
    }

    Context 'Get-PayloadRoot' {
        It 'returns the single top-level folder' {
            $extractDir = Join-Path $TestDrive 'one-folder'
            $null = New-Item -ItemType Directory -Path (Join-Path $extractDir 'start-local-release-1.0')

            (Get-PayloadRoot -ExtractDir $extractDir) | Should -Be (Join-Path (Resolve-Path -LiteralPath $extractDir).ProviderPath 'start-local-release-1.0')
        }

        It 'throws when there are two top-level folders' {
            $extractDir = Join-Path $TestDrive 'two-folders'
            $null = New-Item -ItemType Directory -Path (Join-Path $extractDir 'first')
            $null = New-Item -ItemType Directory -Path (Join-Path $extractDir 'second')

            { Get-PayloadRoot -ExtractDir $extractDir } | Should -Throw -ExceptionType ([System.InvalidOperationException])
        }

        It 'throws when the archive is empty' {
            $extractDir = Join-Path $TestDrive 'empty'
            $null = New-Item -ItemType Directory -Path $extractDir

            { Get-PayloadRoot -ExtractDir $extractDir } | Should -Throw -ExceptionType ([System.InvalidOperationException])
        }
    }

    Context 'Get-LegacyInstallerMessage' {
        It 'points at the old installer of the ref' {
            $message = Get-LegacyInstallerMessage -Ref 'release/1.0'

            $message | Should -BeLike '*https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/release/1.0/VirtoLocal_create_local_files.ps1*'
        }

        It 'passes the ref to the old installer as -branch (R37)' {
            $message = Get-LegacyInstallerMessage -Ref 'release/1.0'

            $message | Should -BeLike '*./VirtoLocal_create_local_files.ps1 -branch release/1.0*'
        }
    }
}

Describe 'Forwarder' -Tag 'Unit' {
    BeforeAll {
        $script:ForwarderLines = Get-Content -LiteralPath "$PSScriptRoot/../../VirtoLocal_create_local_files.ps1"
    }

    It 'is the six lines of SPEC 4.1 (amended): it stops on a failed download and passes the exit code on' {
        $script:ForwarderLines | Should -HaveCount 6
        ($script:ForwarderLines -join "`n") | Should -BeLike "*`$ErrorActionPreference = 'Stop'*"
        $script:ForwarderLines[-1] | Should -BeExactly 'exit $LASTEXITCODE'
    }

    It 'downloads the latest release installer next to itself and forwards its arguments' {
        $text = $script:ForwarderLines -join "`n"
        $text | Should -BeLike '*https://github.com/VirtoCommerce/start-local/releases/latest/download/install.ps1*'
        $text | Should -BeLike '*$PSScriptRoot*'
        $text | Should -BeLike '*@args*'
    }

    It 'parses as PowerShell' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(($script:ForwarderLines -join "`n"), [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
}
