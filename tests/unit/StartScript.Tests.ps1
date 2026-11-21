# start.ps1 end to end after the preflight, with the Docker, dotnet and platform calls mocked: the HTTPS path of a Docker
# platform, the exit contract and the note of a skipped platform.
BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    function script:New-PrebuiltPlatformFolder {
        $path = Join-Path $TestDrive "platform-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $path
        Set-Content -LiteralPath (Join-Path $path 'VirtoCommerce.Platform.Web.dll') -Value 'x'
        $path
    }

    # A platform that answers every call of start.ps1 and accepts admin with the seeded password. The calls that matter for
    # the order checks are recorded in $global:StartScriptCalls (a global: mock bodies run outside this script scope).
    function script:Mock-StartScriptPlatform {
        $global:StartScriptCalls = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-Preflight { }
        Mock Invoke-DockerCompose { $global:StartScriptCalls.Add("compose $($args -join ' ')"); $global:LASTEXITCODE = 0 }
        Mock Watch-Url-Up { $true }
        Mock Start-Sleep { }
        Mock Get-AuthToken { if ($Password -ceq 'store') { 'tok' } else { $null } }
        Mock Start-SourcePlatform { 4242 }
        Mock Stop-SourcePlatform { $false }
        Mock Sync-DevCertificate { $global:StartScriptCalls.Add("sync $VolumeName $ProjectName"); $false }
        Mock Test-DevCertificateTrusted { $true }
        Mock Invoke-RestMethod { [pscustomobject]@{ installedModules = @(1..3 | ForEach-Object { [pscustomobject]@{ id = "Module$_"; version = '3.0.0' } }) } } -ParameterFilter { "$Uri" -like '*/api/platform/diagnostics/systeminfo' }
        Mock Invoke-RestMethod { } -ParameterFilter { "$Uri" -like '*/api/platform/diagnostics/errors' }
        Mock Invoke-RestMethod { [pscustomobject]@{ succeeded = $true } } -ParameterFilter { "$Uri" -like '*/users/admin/resetpassword' }
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 'notification-1' } } -ParameterFilter { "$Uri" -like '*/sampledata/autoinstall' }
        Mock Invoke-RestMethod { [pscustomobject]@{ notifyEvents = [pscustomobject]@{ errorCount = 0; finished = '2026-11-10T00:00:00Z' } } } -ParameterFilter { "$Uri" -like '*/pushnotifications' }
    }

    function script:Invoke-StartScript {
        param([Parameter(Mandatory)][string]$Folder, [switch]$InstallSampleData, [switch]$Interactive)
        $global:LASTEXITCODE = 0
        $arguments = @{ solutionFolder = $Folder; installSampleData = $InstallSampleData }
        if ($Interactive) {
            Mock Test-NonInteractive { $false }
        }
        else {
            $arguments['nonInteractive'] = $true
        }
        $output = & (Join-Path $Folder 'start.ps1') @arguments *>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
}

AfterAll {
    Remove-Variable -Name StartScriptCalls -Scope Global -ErrorAction Ignore
}

Describe 'start.ps1' -Tag 'Unit' {
    BeforeEach {
        Mock-StartScriptPlatform
    }

    Context 'HTTPS with a Docker platform' {
        It 'syncs the dev certificate into the certificates volume before up, prints the trust steps, and exits 0' {
            $folder = New-TestSolutionFolder -ComposeFiles 'docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml', 'docker-compose/elasticsearch.yml' -Values @{ VOLUME_PREFIX = 'acme' }
            $projectName = Get-SolutionProjectName -Document (Read-EnvFile (Join-Path $folder '.env')) -SolutionFolder $folder
            # `dotnet dev-certs https --check --trust` exits 1 for an untrusted certificate; start.ps1 must not pass that on.
            Mock Test-DevCertificateTrusted { $global:LASTEXITCODE = 1; $false }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 0
            @($global:StartScriptCalls) | Should -Be @("sync acme_certs $projectName", 'compose up -d --remove-orphans')
            $run.Output | Should -BeLike '*dotnet dev-certs https --trust*'
            $run.Output | Should -BeLike '*sudo update-ca-certificates*'
            $run.Output | Should -BeLike '*docker compose cp es-setup:/usr/share/elasticsearch/config/certs/ca/ca.crt ./ca.crt*'
            $run.Output | Should -BeLike '*Platform       https://localhost:8090*'
        }

        # up -d leaves a running container alone when only a file in its volume changed, so it would keep the old certificate.
        It 'restarts the containers that serve the certificate after up when it changed: <Label>' -ForEach @(
            @{ Label = 'platform and storefront'; Extra = @('docker-compose/platform.yml', 'docker-compose/frontend.yml'); Restart = 'compose restart vc-platform-web vc-frontend' }
            @{ Label = 'platform only'; Extra = @('docker-compose/platform.yml'); Restart = 'compose restart vc-platform-web' }
        ) {
            $folder = New-TestSolutionFolder -ComposeFiles (@('docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml') + $Extra)
            Mock Sync-DevCertificate { $global:StartScriptCalls.Add('sync'); $true }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 0
            @($global:StartScriptCalls | Where-Object { $_ -like 'sync*' -or $_ -like 'compose up*' -or $_ -like 'compose restart*' }) |
                Should -Be @('sync', 'compose up -d --remove-orphans', $Restart)
        }

        It 'restarts nothing when the certificate did not change' {
            $folder = New-TestSolutionFolder -ComposeFiles 'docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml', 'docker-compose/frontend.yml'

            (Invoke-StartScript $folder).ExitCode | Should -Be 0

            Should -Invoke Invoke-DockerCompose -Times 0 -ParameterFilter { $args -contains 'restart' }
        }

        It 'exits 1 when the restart after a certificate change fails' {
            $folder = New-TestSolutionFolder -ComposeFiles 'docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml'
            Mock Sync-DevCertificate { $true }
            Mock Invoke-DockerCompose { $global:LASTEXITCODE = 3 } -ParameterFilter { $args -contains 'restart' }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike '*docker compose restart failed with exit code 3*'
        }

        It 'prints no trust steps when the certificate is trusted' {
            $folder = New-TestSolutionFolder -ComposeFiles 'docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml'

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 0
            Should -Invoke Sync-DevCertificate -Times 1 -Exactly
            $run.Output | Should -Not -BeLike '*dotnet dev-certs https --trust*'
        }

        It 'does not touch the certificate in HTTP mode' {
            $folder = New-TestSolutionFolder

            (Invoke-StartScript $folder).ExitCode | Should -Be 0

            Should -Invoke Sync-DevCertificate -Times 0
            Should -Invoke Test-DevCertificateTrusted -Times 0
        }

        It 'prints the kibana_system warning of es-setup and exits 1: nothing else tells that Kibana cannot sign in' {
            $folder = New-TestSolutionFolder -ComposeFiles 'docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml', 'docker-compose/elasticsearch.yml', 'docker-compose/kibana.yml'
            Mock Get-KibanaPasswordWarning { $script:KibanaPasswordFailedWarning }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike '*The non-interactive run failed:*'
            $run.Output | Should -BeLike '*es-setup gave up setting the kibana_system password*'
            Should -Invoke Get-KibanaPasswordWarning -Times 1 -Exactly -ParameterFilter { $ComposeFiles -ccontains 'docker-compose/kibana.yml' }
        }

        It 'warns but exits 0 while the kibana_system record is still pending: it may still settle' {
            $folder = New-TestSolutionFolder -ComposeFiles 'docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml', 'docker-compose/elasticsearch.yml', 'docker-compose/kibana.yml'
            Mock Get-KibanaPasswordWarning { 'es-setup has not set the kibana_system password yet, so Kibana cannot sign in until it does.' }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 0
            $run.Output | Should -BeLike '*has not set the kibana_system password yet*'
        }

        It 'exits 1 and does not start the stack when the certificate cannot be synced' {
            $folder = New-TestSolutionFolder -ComposeFiles 'docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml'
            Mock Sync-DevCertificate { throw [System.InvalidOperationException]::new('docker cp failed') }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike '*docker cp failed*'
            Should -Invoke Invoke-DockerCompose -Times 0 -ParameterFilter { $args -contains 'up' }
        }
    }

    Context 'exit contract after the preflight' {
        It 'exits 1 and checks nothing on the platform when docker compose up fails' {
            $folder = New-TestSolutionFolder
            Mock Invoke-DockerCompose { $global:LASTEXITCODE = 17 } -ParameterFilter { $args -contains 'up' }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike '*docker compose up failed with exit code 17*'
            Should -Invoke Watch-Url-Up -Times 0
            Should -Invoke Get-AuthToken -Times 0
        }

        # The sample data runs through the modules' importers: with a failed module it would import partway, and the
        # platform marks it imported anyway. So the run stops there, and the admin password stays as it was.
        It 'stops before the sample data and the admin password when the installed modules check fails' {
            $folder = New-TestSolutionFolder
            Mock Invoke-RestMethod { [pscustomobject]@{ id = 'Module1'; version = '3.0.0'; validationErrors = @('Module dependency Module2 3.0.0 is not installed') } } -ParameterFilter { "$Uri" -like '*/api/platform/diagnostics/errors' }

            $run = Invoke-StartScript $folder -InstallSampleData

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike '*The installed modules check failed, so the sample data and the admin password are skipped*'
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { "$Uri" -like '*/sampledata/*' -or "$Uri" -like '*/users/admin/resetpassword' }
        }

        It 'warns, skips the platform checks and exits 1 when the platform does not become ready' {
            $folder = New-TestSolutionFolder
            Mock Watch-Url-Up { $false }

            $run = Invoke-StartScript $folder -InstallSampleData

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike '*The non-interactive run failed:*'
            $run.Output | Should -BeLike '*did not become ready*'
            Should -Invoke Get-AuthToken -Times 0
            Should -Invoke Invoke-RestMethod -Times 0
        }

        It 'warns, carries on, and exits 1 when the sample data setup fails' {
            $folder = New-TestSolutionFolder
            Mock Invoke-RestMethod { throw [System.Net.Http.HttpRequestException]::new('500 Internal Server Error') } -ParameterFilter { "$Uri" -like '*/sampledata/autoinstall' }

            $run = Invoke-StartScript $folder -InstallSampleData

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike '*The non-interactive run failed:*'
            $run.Output | Should -BeLike '*Sample data setup failed; the solution is running anyway.*'
            $run.Output | Should -BeLike '*... Installed modules checked*'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { "$Uri" -like '*/sampledata/autoinstall' }
        }

        It 'stops with the lockout hint when the platform accepts no admin password (<Mode>)' -ForEach @(
            @{ Mode = 'non-interactive'; Interactive = $false }, @{ Mode = 'interactive'; Interactive = $true }
        ) {
            $folder = New-TestSolutionFolder
            Mock Get-AuthToken { $null }

            $run = Invoke-StartScript $folder -InstallSampleData -Interactive:$Interactive

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike '*accepts none of the admin passwords*locked for 15 minutes*'
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { "$Uri" -like '*/diagnostics/*' -or "$Uri" -like '*/sampledata/*' -or "$Uri" -like '*/users/admin/resetpassword' }
        }

        It 'warns and exits 1 when the platform rejects the new admin password' {
            $folder = New-TestSolutionFolder
            Mock Invoke-RestMethod { [pscustomobject]@{ succeeded = $false; errors = @('PasswordTooShort') } } -ParameterFilter { "$Uri" -like '*/users/admin/resetpassword' }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike '*The non-interactive run failed:*'
            $run.Output | Should -BeLike '*The platform rejected the admin password*PasswordTooShort*'
            $run.Output | Should -Not -BeLike '*Admin password applied*'
        }
    }

    Context 'exit contract of an interactive run' {
        # A person reads the warnings; only an unattended caller needs the exit code to tell.
        It 'warns and exits 0 when the platform does not become ready' {
            $folder = New-TestSolutionFolder
            Mock Watch-Url-Up { $false }

            $run = Invoke-StartScript $folder -Interactive

            $run.ExitCode | Should -Be 0
            $run.Output | Should -BeLike '*did not become ready*'
            $run.Output | Should -Not -BeLike '*The non-interactive run failed*'
        }
    }

    Context 'platform from source' {
        It 'skips the bridge lookup when BIND_ADDRESS already listens everywhere' {
            $platform = New-PrebuiltPlatformFolder
            $folder = New-TestSolutionFolder -ComposeFiles 'docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/frontend.yml' -Values @{ PLATFORM_SOURCE_PATH = $platform; BIND_ADDRESS = '0.0.0.0' }
            Mock Get-DockerBridgeBindAddress { throw 'not expected' }

            (Invoke-StartScript $folder).ExitCode | Should -Be 0

            Should -Invoke Get-DockerBridgeBindAddress -Times 0
        }

        It 'listens on the Docker bridge too when the storefront runs in Docker (<Label>)' -ForEach @(
            @{ Label = 'storefront in Docker'; Files = @('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/frontend.yml'); Expected = 'http://172.17.0.1:8090' }
            @{ Label = 'no storefront'; Files = @('docker-compose.yml', 'docker-compose/postgres.yml'); Expected = $null }
        ) {
            $platform = New-PrebuiltPlatformFolder
            $folder = New-TestSolutionFolder -ComposeFiles $Files -Values @{ PLATFORM_SOURCE_PATH = $platform }
            Mock Get-DockerBridgeBindAddress { '172.17.0.1' }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $settings = Get-Content -LiteralPath (Join-Path $platform 'VirtoCommerce.Platform.Web.settings.json') -Raw | ConvertFrom-Json
            $settings.Kestrel.Endpoints.Main.Url | Should -Be 'http://127.0.0.1:8090'
            $settings.Kestrel.Endpoints.PSObject.Properties['Bridge']?.Value.Url | Should -Be $Expected
        }

        # A source platform holds only the modules it was given (MODULE_SOURCE_PATHS): the check has no minimum count.
        It 'passes the modules check with a single module' {
            $platform = New-PrebuiltPlatformFolder
            $folder = New-TestSolutionFolder -ComposeFiles 'docker-compose.yml', 'docker-compose/postgres.yml' -Values @{ PLATFORM_SOURCE_PATH = $platform }
            Mock Invoke-RestMethod { [pscustomobject]@{ installedModules = @([pscustomobject]@{ id = 'Module1'; version = '3.0.0' }) } } -ParameterFilter { "$Uri" -like '*/api/platform/diagnostics/systeminfo' }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $run.Output | Should -BeLike '*... Installed modules checked*'
        }
    }

    Context 'SKIP_PLATFORM=true' {
        It 'names the URL the platform must listen on (<Mode>)' -ForEach @(
            @{ Mode = 'HTTP'; Https = $false; Scheme = 'http' }
            @{ Mode = 'HTTPS'; Https = $true; Scheme = 'https' }
        ) {
            $files = @('docker-compose.yml') + @(if ($Https) { 'docker-compose/https.yml' }) + @('docker-compose/postgres.yml', 'docker-compose/platform.yml')
            $folder = New-TestSolutionFolder -ComposeFiles $files -Values @{ SKIP_PLATFORM = 'true'; PLATFORM_PORT = '8095' }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 0
            $run.Output | Should -BeLike "*The platform is skipped (SKIP_PLATFORM=true). Run it yourself, or from your IDE, so that it listens on ${Scheme}://localhost:8095.*"
            $run.Output | Should -Not -BeLike '*Platform       http*'
            Should -Invoke Watch-Url-Up -Times 0
        }

        It 'with PLATFORM_SOURCE_PATH names the URL and prints the launch command (<Mode>)' -ForEach @(
            @{ Mode = 'HTTP'; Https = $false; Scheme = 'http' }
            @{ Mode = 'HTTPS'; Https = $true; Scheme = 'https' }
        ) {
            $platform = New-PrebuiltPlatformFolder
            $files = @('docker-compose.yml') + @(if ($Https) { 'docker-compose/https.yml' }) + @('docker-compose/postgres.yml')
            $folder = New-TestSolutionFolder -ComposeFiles $files -Values @{ SKIP_PLATFORM = 'true'; PLATFORM_PORT = '8095'; PLATFORM_SOURCE_PATH = $platform }

            $run = Invoke-StartScript $folder

            $run.ExitCode | Should -Be 0
            $run.Output | Should -BeLike "*The platform is skipped (SKIP_PLATFORM=true). It will listen on ${Scheme}://localhost:8095. Launch it yourself, or from your IDE:*"
            $run.Output | Should -BeLike "*working directory: $platform*"
            $run.Output | Should -BeLike '*command:           dotnet VirtoCommerce.Platform.Web.dll*'
            Should -Invoke Start-SourcePlatform -Times 0
        }
    }
}
