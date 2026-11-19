BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

Describe 'Unusual command sequences' -Tag 'Unit' {
    Context 'Read-YesNo' {
        It 'asks again after an answer that is neither yes nor no' {
            $script:answers = [System.Collections.Generic.Queue[string]]::new([string[]]@('maybe', 'n'))
            Mock Read-Host { $script:answers.Dequeue() }

            Read-YesNo -Prompt 'Build the solution now?' -Default $true -NonInteractive $false -WarningAction SilentlyContinue | Should -BeFalse

            Should -Invoke Read-Host -Times 2 -Exactly
        }

        It 'takes the default for an empty answer' {
            Mock Read-Host { '' }

            Read-YesNo -Prompt 'Update vc-build?' -Default $true -NonInteractive $false | Should -BeTrue
        }
    }

    Context 'Get-MissingRequiredKeys -ForStart' {
        It 'requires only COMPOSE_FILE: start never reads the release channel' {
            Get-MissingRequiredKeys -EnvValues @{ COMPOSE_FILE = 'docker-compose.yml'; RELEASE_CHANNEL = '' } -ForStart | Should -BeNullOrEmpty
            Get-MissingRequiredKeys -EnvValues @{ COMPOSE_FILE = ''; RELEASE_CHANNEL = '' } -ForStart | Should -Be @('COMPOSE_FILE')
        }

        It 'still requires the release channel for build and install' {
            Get-MissingRequiredKeys -EnvValues @{ COMPOSE_FILE = 'docker-compose.yml'; RELEASE_CHANNEL = '' } | Should -Be @('RELEASE_CHANNEL')
        }
    }

    Context 'Request-RequiredEnvKeys -BaseDirectory' {
        It 'stores a relative manifest path answered at the prompt as absolute, against the base directory' {
            $document = ConvertFrom-EnvText "COMPOSE_FILE=docker-compose.yml`nRELEASE_CHANNEL=custom`nCUSTOM_PACKAGES_JSON=`n"
            Mock Read-Host { 'my-packages.json' }
            $base = Join-Path $TestDrive 'caller'

            $null = Request-RequiredEnvKeys -Document $document -NonInteractive $false -BaseDirectory $base

            Get-EnvValue -Document $document -Key 'CUSTOM_PACKAGES_JSON' | Should -BeExactly (Join-Path $base 'my-packages.json')
        }
    }

    Context 'dropped dependent files' {
        It 'names the switch that brings Kibana back when Elasticsearch is off' {
            $files = [string[]]@((Get-DefaultComposeFiles -Provider postgres) | Where-Object { $_ -notlike '*elasticsearch*' })

            $null = Update-ComposeFileList -ComposeFiles $files -HasSourceModules $false -WarningVariable warnings -WarningAction SilentlyContinue

            ($warnings -join "`n") | Should -Match '-skipKibana:\$false'
        }
    }

    Context 'Stop-SourcePlatform' {
        BeforeEach {
            $script:logDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:logDir
            Set-Content -LiteralPath (Join-Path $script:logDir 'platform.pid') -Value '4242;1'
        }

        It 'keeps the pid file and throws naming the pid when the kill fails' {
            Mock Get-RunningSourcePlatform {
                $process = [pscustomobject]@{ Id = 4242 }
                $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($tree) throw [System.ComponentModel.Win32Exception]::new(1, 'Operation not permitted') }
                $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) $true }
                $process
            }

            { Stop-SourcePlatform -LogDir $script:logDir } | Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*4242*Operation not permitted*'
            Join-Path $script:logDir 'platform.pid' | Should -Exist
        }

        It 'keeps the pid file and throws when the process outlives the wait' {
            Mock Wait-ProcessExit { $false }
            Mock Get-RunningSourcePlatform {
                $process = [pscustomobject]@{ Id = 4242 }
                $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($tree) }
                $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) $false }
                $process
            }

            { Stop-SourcePlatform -LogDir $script:logDir } | Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*4242*'
            Join-Path $script:logDir 'platform.pid' | Should -Exist
        }
    }
}
