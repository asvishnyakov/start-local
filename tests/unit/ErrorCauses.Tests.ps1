BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

# Each error names its real cause, not only a guess at it.
Describe 'Errors that keep their cause' -Tag 'Unit' {
    Context 'Write-ScriptError' {
        It 'prints only the message for the scripts'' own errors' {
            $record = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('docker compose up failed.'), 'id', 'InvalidOperation', $null)

            $printed = Write-ScriptError -ErrorRecord $record 6>&1 | Out-String

            $printed | Should -Match 'Error: docker compose up failed\.'
            $printed | Should -Not -Match 'At '
        }

        It 'adds where an unexpected error happened' {
            try { $null.Method() } catch { $record = $_ }

            $printed = Write-ScriptError -ErrorRecord $record 6>&1 | Out-String

            $printed | Should -Match 'null-valued expression'
            $printed | Should -Match 'ErrorCauses\.Tests\.ps1:\d+'
        }
    }

    Context 'preflight' {
        It 'keeps the reason the Compose plugin is not available' {
            Mock Get-ComposeVersion { throw [System.InvalidOperationException]::new("'docker compose version --short' failed: unknown command: docker compose") }
            Mock Test-DockerCommand { $true }
            Mock Get-DockerDaemonError { $null }
            Mock Get-ProjectPublishedPorts { [int[]]@() }
            Mock Test-PortInUse { $false }
            $values = [ordered]@{ COMPOSE_FILE = 'docker-compose.yml;docker-compose/postgres.yml;docker-compose/platform.yml'; RELEASE_CHANNEL = 'stable'; PGSQL_PORT = '5432'; PLATFORM_PORT = '8090' }

            $errors = Invoke-Preflight -EnvValues $values -ComposeFiles ([string[]]@('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml')) -NonInteractive $true

            ($errors -join "`n") | Should -Match 'unknown command: docker compose'
        }
    }

    Context 'downloads during build' {
        It '<Name> names what it downloads and from where' -ForEach @(
            @{ Name = 'Get-StableJson'; Call = { Get-StableJson }; Url = '*bundles*stable.json*' }
            @{ Name = 'Get-LatestFrontendReleaseUrl'; Call = { Get-LatestFrontendReleaseUrl }; Url = '*api.github.com*vc-frontend*' }
        ) {
            Mock Invoke-RestMethod { throw [System.Net.Http.HttpRequestException]::new('No such host is known.') }

            { & $Call } | Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage "$Url*No such host is known.*"
        }
    }

    Context 'Get-AuthToken' {
        It 'returns $null quietly when the platform refuses the password (HTTP 400, invalid_grant)' {
            Mock Invoke-WebRequest {
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 400 (Bad Request).', $response)
                $record = [System.Management.Automation.ErrorRecord]::new($exception, 'WebCmdletWebResponseException', 'InvalidOperation', $null)
                $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":"invalid_grant","code":"login_failed","error_description":"Login attempt failed. Please check your credentials."}')
                throw $record
            }

            $token = Get-AuthToken 'https://localhost:8090/connect/token' 'admin' 'wrong' -WarningVariable warnings -WarningAction SilentlyContinue

            $token | Should -BeNullOrEmpty
            $warnings | Should -BeNullOrEmpty
        }

        It 'returns $null and warns with the reason when the platform cannot answer' {
            Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('Connection refused (localhost:8090)') }

            $token = Get-AuthToken 'https://localhost:8090/connect/token' 'admin' 'store' -WarningVariable warnings -WarningAction SilentlyContinue

            $token | Should -BeNullOrEmpty
            ($warnings -join "`n") | Should -Match 'Connection refused'
        }
    }

    Context 'Watch-Url-Up' {
        It 'ends with the last reason when the URL never answers 200' {
            Mock Start-Sleep { }
            Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('Connection refused (localhost:8090)') }

            $printed = Watch-Url-Up -ApiUrl 'https://localhost:8090/health' -TimeoutMinutes 1 -RetrySeconds 30 -WaitSeconds 0 6>&1 | Out-String

            $printed | Should -Match 'Connection refused'
        }

        It 'names a status other than 200' {
            Mock Start-Sleep { }
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 204 } }

            $printed = Watch-Url-Up -ApiUrl 'https://localhost:8090/health' -TimeoutMinutes 1 -RetrySeconds 30 -WaitSeconds 0 6>&1 | Out-String

            $printed | Should -Match '204'
        }
    }

    Context 'module.manifest' {
        It 'says why a manifest gives no module id' {
            $module = Join-Path $TestDrive 'broken-module'
            $null = New-Item -ItemType Directory -Path $module
            Set-Content -LiteralPath (Join-Path $module 'module.manifest') -Value '<module><id>unclosed'

            (Get-ModuleSourceKind -Paths @($module)).Message | Should -Match 'not valid XML|no <id>'
        }
    }

    Context 'Get-ShadowedKeys' {
        It 'throws a FormatException for user secrets that are not valid JSON, so start can warn' {
            { Get-ShadowedKeys -SecretsJson '{ "a": ' -SettingKeys @('a') } | Should -Throw -ExceptionType ([System.FormatException])
        }
    }

    Context 'removing Docker resources' {
        BeforeAll {
            # A function shadows the docker executable inside this scope; $script:DockerReply decides its answer.
            function script:docker {
                $global:LASTEXITCODE = $script:DockerReply.ExitCode
                if ($script:DockerReply.Error) { Write-Error -Message $script:DockerReply.Error -ErrorAction Continue }
            }
        }

        It 'treats "No such <Kind>" as already removed' -ForEach @(
            @{ Kind = 'volume'; DockerError = 'Error response from daemon: get x: no such volume' }
            @{ Kind = 'image'; DockerError = 'Error response from daemon: No such image: vc-platform:x-latest' }
        ) {
            # DockerError, not Error: a test-case key named Error would shadow the automatic $Error variable.
            $script:DockerReply = @{ ExitCode = 1; Error = $DockerError }

            Remove-DockerResource -Kind $Kind -Name 'x' | Should -BeNullOrEmpty
        }

        It 'returns the reason for any other failure' {
            $script:DockerReply = @{ ExitCode = 1; Error = 'Error response from daemon: remove x: volume is in use' }

            Remove-DockerResource -Kind volume -Name 'x' | Should -Match 'volume is in use'
        }

        It 'returns nothing after a removal' {
            $script:DockerReply = @{ ExitCode = 0; Error = $null }

            Remove-DockerResource -Kind image -Name 'x' | Should -BeNullOrEmpty
        }
    }
}
