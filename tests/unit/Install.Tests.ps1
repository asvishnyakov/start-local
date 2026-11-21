BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    # Runs the installer over $Folder with the repository as the payload. Returns the exit code and everything it printed.
    function script:Invoke-Install {
        param([Parameter(Mandatory)][string]$Folder, [hashtable]$Bound = @{}, [bool]$NonInteractive = $true)
        $stream = @(Invoke-PayloadInstall -PayloadPath (Get-TestRepositoryRoot) -TargetFolder $Folder -Bound $Bound -NonInteractive $NonInteractive *>&1)
        # install.ps1 does `exit (Invoke-PayloadInstall ...)`: anything else on the success stream turns the exit code into an
        # array, which exits 0. So the success stream must hold exactly one [int].
        $recordTypes = [System.Management.Automation.ErrorRecord], [System.Management.Automation.WarningRecord], [System.Management.Automation.VerboseRecord],
            [System.Management.Automation.DebugRecord], [System.Management.Automation.InformationRecord]
        $success = @($stream | Where-Object { $item = $_; -not ($recordTypes | Where-Object { $item -is $_ }) })
        if ($success.Count -ne 1 -or $success[0] -isnot [int]) {
            throw [System.InvalidOperationException]::new("Invoke-PayloadInstall must emit exactly one [int] on the success stream; it emitted $($success.Count) object(s): $(($success | ForEach-Object { "[$($_.GetType().Name)] $_" }) -join '; ')")
        }
        [pscustomobject]@{
            ExitCode = $success[0]
            Output   = $stream | Where-Object { $_ -isnot [int] } | Out-String
        }
    }

    function script:New-InstallFolder {
        Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    function script:Read-InstallEnv {
        param([Parameter(Mandatory)][string]$Folder)
        Get-EnvTable -Document (Read-EnvFile (Join-Path $Folder '.env'))
    }

    $script:DefaultOptions = @{ dbProvider = 'postgres'; releaseChannel = 'stable'; nonInteractive = $true }
}

Describe 'Invoke-PayloadInstall' -Tag 'Unit' {
    BeforeEach {
        Mock Update-VcBuildTool { $true }
        Mock Invoke-SolutionBuild { 0 }
        $folder = New-InstallFolder
    }

    # Sample data is opt-in: the platform imports it into any database that never had it, the user's included, so no
    # run imports it unless -installSampleData asks.
    Context 'sample data' {
        It 'does not import sample data unless asked, over a fresh folder or an earlier install (<Label>)' -ForEach @(
            @{ Label = 'fresh'; Earlier = $false }, @{ Label = 'earlier install'; Earlier = $true }
        ) {
            if ($Earlier) {
                $null = New-Item -ItemType Directory -Path $folder
                Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../fixtures/env/layout1-postgres.env') -Destination (Join-Path $folder '.env')
                Set-Content -LiteralPath (Join-Path $folder 'start-VC-solution.ps1') -Value '# earlier install'
            }

            $null = Invoke-Install -Folder $folder -Bound $script:DefaultOptions

            Should -Invoke Invoke-SolutionBuild -Times 1 -Exactly -ParameterFilter { $InstallSampleData -eq $false }
        }

        It 'imports sample data when -installSampleData is passed' {
            $null = Invoke-Install -Folder $folder -Bound ($script:DefaultOptions + @{ installSampleData = [switch]$true })

            Should -Invoke Invoke-SolutionBuild -Times 1 -Exactly -ParameterFilter { $InstallSampleData -eq $true }
        }
    }

    Context 'fresh install' {
        It 'creates .env with generated secrets, the default HTTPS compose list and layout 2' {
            $result = Invoke-Install -Folder $folder -Bound $script:DefaultOptions

            $result.ExitCode | Should -Be 0
            $values = Read-InstallEnv $folder
            foreach ($key in 'DB_PASSWORD', 'REDIS_PASSWORD', 'ELASTIC_PASSWORD', 'KIBANA_PASSWORD') {
                $values[$key] | Should -Match '^[A-Za-z0-9]{16}$'
            }
            $values['COMPOSE_FILE'] | Should -BeExactly (ConvertTo-ComposeFileValue (Get-DefaultComposeFiles -Provider postgres -Https $true))
            $values['START_LOCAL_LAYOUT'] | Should -Be '2'
            $values['RELEASE_CHANNEL'] | Should -Be 'stable'
        }

        It 'copies the payload but no old-named script' {
            $null = Invoke-Install -Folder $folder -Bound $script:DefaultOptions

            foreach ($relative in 'install.ps1', 'build.ps1', 'start.ps1', '.env.example', 'docker-compose.yml', 'scripts/_init.ps1') {
                Join-Path $folder $relative | Should -Exist
            }
            foreach ($name in Get-LegacyScriptNames) {
                Join-Path $folder $name | Should -Not -Exist
            }
        }

        It 'builds once with the per-run switches only' {
            $null = Invoke-Install -Folder $folder -Bound ($script:DefaultOptions + @{ installSampleData = [switch]$true })

            Should -Invoke Update-VcBuildTool -Times 1 -Exactly
            Should -Invoke Invoke-SolutionBuild -Times 1 -Exactly -ParameterFilter { $NonInteractive -eq $true -and $InstallSampleData -eq $true }
        }

        It 'returns the exit code of the build' {
            Mock Invoke-SolutionBuild { 7 }
            (Invoke-Install -Folder $folder -Bound $script:DefaultOptions).ExitCode | Should -Be 7
        }

        It 'persists -branch as START_LOCAL_REF' {
            $null = Invoke-Install -Folder $folder -Bound ($script:DefaultOptions + @{ branch = 'release/2.0' })
            (Read-InstallEnv $folder)['START_LOCAL_REF'] | Should -Be 'release/2.0'
        }

        It 'does not ask the per-run questions when non-interactive' {
            Mock Read-Host { throw 'asked' }
            { Invoke-Install -Folder $folder -Bound $script:DefaultOptions } | Should -Not -Throw
        }
    }

    Context 're-run over a used folder' {
        It 'keeps the secrets and lists the user files after the built-in ones' {
            $null = Invoke-Install -Folder $folder -Bound $script:DefaultOptions
            $envPath = Join-Path $folder '.env'
            $document = Read-EnvFile $envPath
            Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value ((Get-EnvValue $document 'COMPOSE_FILE') + ';my.override.yml')
            Write-EnvFile -Document $document -Path $envPath
            $secretsBefore = Read-InstallEnv $folder

            $result = Invoke-Install -Folder $folder -Bound $script:DefaultOptions

            $result.ExitCode | Should -Be 0
            $after = Read-InstallEnv $folder
            foreach ($key in 'DB_PASSWORD', 'REDIS_PASSWORD', 'ELASTIC_PASSWORD', 'KIBANA_PASSWORD') {
                $after[$key] | Should -BeExactly $secretsBefore[$key]
            }
            (Get-ComposeFileList $after['COMPOSE_FILE'])[-1] | Should -Be 'my.override.yml'
        }

        It 'keeps the user files with no parameters at all' {
            $null = Invoke-Install -Folder $folder -Bound $script:DefaultOptions
            $envPath = Join-Path $folder '.env'
            $document = Read-EnvFile $envPath
            Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value ((Get-EnvValue $document 'COMPOSE_FILE') + ';my.override.yml')
            Write-EnvFile -Document $document -Path $envPath
            $before = [System.IO.File]::ReadAllBytes($envPath)

            (Invoke-Install -Folder $folder -Bound @{ nonInteractive = $true }).ExitCode | Should -Be 0

            [System.IO.File]::ReadAllBytes($envPath) | Should -Be $before
        }

        It 'replaces a changed script but keeps logs and the pid file' {
            $null = Invoke-Install -Folder $folder -Bound $script:DefaultOptions
            Set-Content -LiteralPath (Join-Path $folder 'start.ps1') -Value 'old'
            $null = New-Item -ItemType File -Path (Join-Path $folder 'logs/platform.pid') -Force -Value '123'

            $null = Invoke-Install -Folder $folder -Bound $script:DefaultOptions

            Get-Content -LiteralPath (Join-Path $folder 'start.ps1') -Raw | Should -Be (Get-Content -LiteralPath (Join-Path (Get-TestRepositoryRoot) 'start.ps1') -Raw)
            Get-Content -LiteralPath (Join-Path $folder 'logs/platform.pid') -Raw | Should -Be '123'
        }
    }

    Context 'layout-1 folder' {
        BeforeEach {
            $null = New-Item -ItemType Directory -Path $folder
            Copy-Item -LiteralPath (Join-Path (Get-TestRepositoryRoot) 'tests/fixtures/env/layout1-postgres.env') -Destination (Join-Path $folder '.env')
            Set-Content -LiteralPath (Join-Path $folder 'start-VC-solution.ps1') -Value '# the old script'
        }

        It 'migrates a layout-1 .env that has a hand-added COMPOSE_FILE' {
            $envPath = Join-Path $folder '.env'
            Add-Content -LiteralPath $envPath -Value 'COMPOSE_FILE=docker-compose.yml;docker-compose.postgres.yml'

            $result = Invoke-Install -Folder $folder -Bound @{ releaseChannel = 'stable'; nonInteractive = $true }

            $result.ExitCode | Should -Be 0
            $values = Read-InstallEnv $folder
            $values['VOLUME_PREFIX'] | Should -Be 'virto'
            $values.Contains('DB_PROVIDER') | Should -BeFalse
        }

        It 'checks the migration before it copies anything: a bad .env leaves the old scripts in place' {
            Copy-Item -LiteralPath (Join-Path (Get-TestRepositoryRoot) 'tests/fixtures/env/layout1-bad-provider.env') -Destination (Join-Path $folder '.env') -Force

            { Invoke-Install -Folder $folder -Bound @{ releaseChannel = 'stable'; nonInteractive = $true } } | Should -Throw -ExpectedMessage '*DB_PROVIDER*'

            Get-Content -LiteralPath (Join-Path $folder 'start-VC-solution.ps1') -Raw | Should -Match 'the old script'
            Join-Path $folder 'install.ps1' | Should -Not -Exist
        }

        It 'migrates .env and keeps its values' {
            $result = Invoke-Install -Folder $folder -Bound @{ releaseChannel = 'stable'; nonInteractive = $true }

            $result.ExitCode | Should -Be 0
            $values = Read-InstallEnv $folder
            $values['START_LOCAL_LAYOUT'] | Should -Be '2'
            $values.Contains('DB_PROVIDER') | Should -BeFalse
            $values['DB_PASSWORD'] | Should -BeExactly 'pgPass1'
            $values['VOLUME_PREFIX'] | Should -Be 'virto'
            $values['COMPOSE_FILE'] | Should -Match 'docker-compose/postgres\.yml'
            $values['COMPOSE_FILE'] | Should -Not -Match 'https'
        }

        It 'builds without asking: the 1.x images cannot run under the new compose files' {
            Mock Read-Host { 'n' } -ParameterFilter { $Prompt -like 'Build*' }
            Mock Read-Host { 'y' }

            $result = Invoke-Install -Folder $folder -Bound @{ releaseChannel = 'stable' } -NonInteractive $false

            $result.ExitCode | Should -Be 0
            Should -Invoke Read-Host -Times 0 -Exactly -ParameterFilter { $Prompt -like 'Build*' }
            Should -Invoke Invoke-SolutionBuild -Times 1 -Exactly
        }

        It 'overwrites the old script with its guard and adds no other old-named script' {
            $null = Invoke-Install -Folder $folder -Bound @{ releaseChannel = 'stable'; nonInteractive = $true }

            Get-Content -LiteralPath (Join-Path $folder 'start-VC-solution.ps1') -Raw | Should -Be (Get-Content -LiteralPath (Join-Path (Get-TestRepositoryRoot) 'start-VC-solution.ps1') -Raw)
            foreach ($name in 'build-VC-solution.ps1', 'stop-VC-solution.ps1', 'remove-VC-solution.ps1') {
                Join-Path $folder $name | Should -Not -Exist
            }
        }
    }

    Context 'required keys' {
        It 'non-interactive with missing keys fails naming them' {
            $result = Invoke-Install -Folder $folder -Bound @{ nonInteractive = $true }

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'COMPOSE_FILE'
            $result.Output | Should -Match 'RELEASE_CHANNEL'
            Should -Invoke Invoke-SolutionBuild -Times 0 -Exactly
        }

        It 'still fills the secrets and saves what was given before it fails' {
            $null = Invoke-Install -Folder $folder -Bound @{ releaseChannel = 'edge'; nonInteractive = $true }

            $values = Read-InstallEnv $folder
            $values['RELEASE_CHANNEL'] | Should -Be 'edge'
            $values['DB_PASSWORD'] | Should -Match '^[A-Za-z0-9]{16}$'
        }

        It 'names CUSTOM_PACKAGES_JSON on the custom channel' {
            $result = Invoke-Install -Folder $folder -Bound @{ dbProvider = 'postgres'; releaseChannel = 'custom'; nonInteractive = $true }

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'CUSTOM_PACKAGES_JSON'
        }

        It 'asks the interactive questions and applies the switches that waited for the provider answer' {
            Mock Read-Host { '1' } -ParameterFilter { $Prompt -like 'Database provider*' }
            Mock Read-Host { '' }

            $result = Invoke-Install -Folder $folder -Bound @{ releaseChannel = 'stable'; allowInsecureHttp = $true } -NonInteractive $false

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Not -Match 'could not be applied'
            $values = Read-InstallEnv $folder
            $values['COMPOSE_FILE'] | Should -Not -Match 'https'
            $values['FRONTEND_PORT'] | Should -Be '80'
            # Both per-run questions defaulted to yes.
            Should -Invoke Update-VcBuildTool -Times 1 -Exactly
            Should -Invoke Invoke-SolutionBuild -Times 1 -Exactly -ParameterFilter { $NonInteractive -eq $false }
        }

        It 'saves no Docker platform file for -skipPlatform when the provider comes from the prompt' {
            Mock Read-Host { '1' } -ParameterFilter { $Prompt -like 'Database provider*' }
            Mock Read-Host { 'n' } -ParameterFilter { $Prompt -like 'Build*' }
            Mock Read-Host { '' }

            $result = Invoke-Install -Folder $folder -Bound @{ releaseChannel = 'stable'; skipPlatform = $true } -NonInteractive $false

            $result.ExitCode | Should -Be 0
            $values = Read-InstallEnv $folder
            $values['SKIP_PLATFORM'] | Should -Be 'true'
            $values['COMPOSE_FILE'] | Should -Not -Match 'docker-compose/platform'
        }

        It 'skips the build when the answer to "build now" is no' {
            Mock Read-Host { 'n' } -ParameterFilter { $Prompt -like 'Build*' }
            Mock Read-Host { 'y' }

            $result = Invoke-Install -Folder $folder -Bound $script:DefaultOptions -NonInteractive $false

            $result.ExitCode | Should -Be 0
            Should -Invoke Update-VcBuildTool -Times 1 -Exactly
            Should -Invoke Invoke-SolutionBuild -Times 0 -Exactly
        }
    }

    Context '-allowInsecureHttp' {
        It 'lists no .https overlays and moves FRONTEND_PORT to 80' {
            $result = Invoke-Install -Folder $folder -Bound ($script:DefaultOptions + @{ allowInsecureHttp = $true })

            $result.ExitCode | Should -Be 0
            $values = Read-InstallEnv $folder
            $values['COMPOSE_FILE'] | Should -Not -Match '\.https\.yml'
            $values['FRONTEND_PORT'] | Should -Be '80'
        }
    }

    Context '-customPackagesJson' {
        It 'stores a relative path as absolute, against the directory the installer was run from' {
            $null = Invoke-Install -Folder $folder -Bound @{ dbProvider = 'postgres'; releaseChannel = 'custom'; customPackagesJson = 'packages.json'; nonInteractive = $true }

            (Read-InstallEnv $folder)['CUSTOM_PACKAGES_JSON'] | Should -BeExactly ([System.IO.Path]::GetFullPath('packages.json', (Get-Location).ProviderPath))
        }
    }

    Context '.env written by a wrapper beforehand' {
        It 'keeps COMPOSE_FILE with the optional file and fills only the empty keys' {
            $null = New-Item -ItemType Directory -Path $folder
            $composeFile = (ConvertTo-ComposeFileValue (Get-DefaultComposeFiles -Provider mysql -Https $true)) + ';docker-compose/es-limited.yml'
            $document = Read-EnvFile (Join-Path (Get-TestRepositoryRoot) '.env.example')
            Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value $composeFile
            Set-EnvValue -Document $document -Key 'DB_PASSWORD' -Value 'wrapperPassword1'
            Set-EnvValue -Document $document -Key 'PLATFORM_PORT' -Value '9000'
            Write-EnvFile -Document $document -Path (Join-Path $folder '.env')

            $result = Invoke-Install -Folder $folder -Bound @{ releaseChannel = 'stable'; nonInteractive = $true }

            $result.ExitCode | Should -Be 0
            $values = Read-InstallEnv $folder
            $values['COMPOSE_FILE'] | Should -BeExactly $composeFile
            $values['DB_PASSWORD'] | Should -BeExactly 'wrapperPassword1'
            $values['PLATFORM_PORT'] | Should -Be '9000'
            $values['REDIS_PASSWORD'] | Should -Match '^[A-Za-z0-9]{16}$'
            $values['RELEASE_CHANNEL'] | Should -Be 'stable'
        }

        It 'treats a file with no layout marker but a COMPOSE_FILE as layout 2, adding the keys it lacks' {
            $null = New-Item -ItemType Directory -Path $folder
            $composeFile = (ConvertTo-ComposeFileValue (Get-DefaultComposeFiles -Provider postgres -Https $true)) + ';docker-compose/es-limited.yml'
            Set-Content -LiteralPath (Join-Path $folder '.env') -Value "COMPOSE_FILE=$composeFile"

            $result = Invoke-Install -Folder $folder -Bound @{ releaseChannel = 'stable'; nonInteractive = $true }

            $result.ExitCode | Should -Be 0
            $values = Read-InstallEnv $folder
            $values['COMPOSE_FILE'] | Should -BeExactly $composeFile
            $values['START_LOCAL_LAYOUT'] | Should -Be '2'
            $values['PLATFORM_PORT'] | Should -Be '8090'
            $values['DB_PASSWORD'] | Should -Match '^[A-Za-z0-9]{16}$'
        }

        It 'leaves a layout-1 file without DB_PROVIDER to migration: fails naming DB_PROVIDER, .env untouched' {
            $null = New-Item -ItemType Directory -Path $folder
            $envPath = Join-Path $folder '.env'
            Copy-Item -LiteralPath (Join-Path (Get-TestRepositoryRoot) 'tests/fixtures/env/layout1-no-provider.env') -Destination $envPath
            $before = [System.IO.File]::ReadAllBytes($envPath)

            $failure = $null
            try {
                $null = Invoke-Install -Folder $folder -Bound @{ dbProvider = 'postgres'; releaseChannel = 'stable'; nonInteractive = $true }
            } catch {
                $failure = $_
            }

            $failure | Should -Not -BeNullOrEmpty
            $failure.Exception.Message | Should -Match 'DB_PROVIDER'
            [System.IO.File]::ReadAllBytes($envPath) | Should -Be $before
            (Get-Content -LiteralPath $envPath -Raw) | Should -Not -Match 'START_LOCAL_LAYOUT=2'
            Should -Invoke Invoke-SolutionBuild -Times 0 -Exactly
        }
    }
}

Describe 'Invoke-SolutionBuild' -Tag 'Unit' {
    BeforeEach {
        $folder = New-InstallFolder
        $null = New-Item -ItemType Directory -Path $folder
        $recordPath = Join-Path $folder 'arguments.txt'
        Set-Content -LiteralPath (Join-Path $folder 'build.ps1') -Value @"
param([string]`$solutionFolder, [switch]`$installSampleData, [switch]`$nonInteractive, [Parameter(ValueFromRemainingArguments)]`$remaining)
Set-Content -LiteralPath '$recordPath' -Value "`$(`$installSampleData.IsPresent) `$(`$nonInteractive.IsPresent) `$(`$remaining.Count)"
exit 3
"@
    }

    It 'runs the folder''s build.ps1 with the per-run switches only and returns its exit code' {
        Invoke-SolutionBuild -TargetFolder $folder -InstallSampleData $true -NonInteractive $true | Should -Be 3
        (Get-Content -LiteralPath $recordPath -Raw).Trim() | Should -Be 'True True 0'
    }

    It 'passes -nonInteractive only when asked' {
        Invoke-SolutionBuild -TargetFolder $folder -InstallSampleData $false -NonInteractive $false | Should -Be 3
        (Get-Content -LiteralPath $recordPath -Raw).Trim() | Should -Be 'False False 0'
    }

    It 'throws when the payload delivered no build.ps1' {
        Remove-Item -LiteralPath (Join-Path $folder 'build.ps1')
        { Invoke-SolutionBuild -TargetFolder $folder -InstallSampleData $false -NonInteractive $true } | Should -Throw '*build.ps1*'
    }
}

Describe 'Copy-Payload guards' -Tag 'Unit' {
    It 'overwrites each existing old-named script with its guard and adds none' {
        $destination = New-InstallFolder
        $null = New-Item -ItemType Directory -Path $destination
        Set-Content -LiteralPath (Join-Path $destination 'remove-VC-solution.ps1') -Value '# the old script'

        Copy-Payload -Root (Get-TestRepositoryRoot) -Destination $destination

        Get-Content -LiteralPath (Join-Path $destination 'remove-VC-solution.ps1') -Raw | Should -Be (Get-Content -LiteralPath (Join-Path (Get-TestRepositoryRoot) 'remove-VC-solution.ps1') -Raw)
        foreach ($name in 'build-VC-solution.ps1', 'start-VC-solution.ps1', 'stop-VC-solution.ps1') {
            Join-Path $destination $name | Should -Not -Exist
        }
    }
}
