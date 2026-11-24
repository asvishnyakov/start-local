BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    function New-PreflightFiles {
        # The normalized file list of a stack: base, postgres, platform and the named extras.
        param([string[]]$Extra = @())

        [string[]]@('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml') + $Extra
    }

    function New-PreflightEnv {
        param([hashtable]$Override = @{})

        $values = [ordered]@{
            COMPOSE_FILE     = 'docker-compose.yml;docker-compose/postgres.yml;docker-compose/platform.yml'
            RELEASE_CHANNEL  = 'stable'
            PGSQL_PORT       = '5432'
            MYSQL_PORT       = '3306'
            MSSQL_PORT       = '1433'
            ES_PORT          = '9200'
            KIBANA_PORT      = '5601'
            REDIS_PORT       = '6379'
            PLATFORM_PORT    = '8090'
            FRONTEND_PORT    = '443'
        }
        foreach ($key in $Override.Keys) {
            $values[$key] = $Override[$key]
        }
        $values
    }
}

Describe 'Preflight' -Tag 'Unit' {
    Context 'Get-RequiredPorts' {
        It 'follows COMPOSE_FILE: postgres, platform and redis need only their own ports' {
            $files = New-PreflightFiles -Extra 'docker-compose/redis.yml'

            $ports = Get-RequiredPorts -EnvValues (New-PreflightEnv) -ComposeFiles $files

            ($ports | ForEach-Object { $_.Key }) | Should -Be @('PGSQL_PORT', 'PLATFORM_PORT', 'REDIS_PORT')
            ($ports | ForEach-Object { $_.Port }) | Should -Be @(5432, 8090, 6379)
        }

        It 'maps each provider to its own port key' -TestCases @(
            @{ Provider = 'mysql'; Key = 'MYSQL_PORT'; Port = 3306 }
            @{ Provider = 'sqlserver'; Key = 'MSSQL_PORT'; Port = 1433 }
        ) {
            $files = [string[]]@('docker-compose.yml', "docker-compose/$Provider.yml")

            $ports = Get-RequiredPorts -EnvValues (New-PreflightEnv) -ComposeFiles $files

            @($ports).Count | Should -Be 1
            $ports[0].Key | Should -Be $Key
            $ports[0].Port | Should -Be $Port
        }

        It 'maps elasticsearch, kibana and the storefront' {
            $files = New-PreflightFiles -Extra 'docker-compose/elasticsearch.yml', 'docker-compose/kibana.yml', 'docker-compose/frontend.yml'

            $ports = Get-RequiredPorts -EnvValues (New-PreflightEnv) -ComposeFiles $files

            ($ports | ForEach-Object { $_.Key }) | Should -Be @('PGSQL_PORT', 'PLATFORM_PORT', 'ES_PORT', 'KIBANA_PORT', 'FRONTEND_PORT')
        }

        It 'a source platform still requires PLATFORM_PORT' {
            $files = [string[]]@('docker-compose.yml', 'docker-compose/postgres.yml')
            $values = New-PreflightEnv @{ PLATFORM_SOURCE_PATH = '/src/vc-platform' }

            $ports = Get-RequiredPorts -EnvValues $values -ComposeFiles $files

            ($ports | ForEach-Object { $_.Key }) | Should -Be @('PGSQL_PORT', 'PLATFORM_PORT')
        }

        It 'a skipped source platform needs no PLATFORM_PORT' {
            $files = [string[]]@('docker-compose.yml', 'docker-compose/postgres.yml')
            $values = New-PreflightEnv @{ PLATFORM_SOURCE_PATH = '/src/vc-platform'; SKIP_PLATFORM = 'true' }

            $ports = Get-RequiredPorts -EnvValues $values -ComposeFiles $files

            ($ports | ForEach-Object { $_.Key }) | Should -Be @('PGSQL_PORT')
        }

        It 'own published ports are excluded' {
            $ports = Get-RequiredPorts -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -ExcludePorts 8090

            ($ports | ForEach-Object { $_.Key }) | Should -Be @('PGSQL_PORT')
        }

        It 'reports a port key that .env leaves out: Compose would publish a random port' {
            $values = New-PreflightEnv
            $values.Remove('PGSQL_PORT')

            { Get-RequiredPorts -EnvValues $values -ComposeFiles (New-PreflightFiles) } |
                Should -Throw -ExceptionType ([System.FormatException]) -ExpectedMessage '*PGSQL_PORT is empty*5432*'
        }

        It 'names the key when its value is not a port number' {
            { Get-RequiredPorts -EnvValues (New-PreflightEnv @{ PLATFORM_PORT = 'abc' }) -ComposeFiles (New-PreflightFiles) } |
                Should -Throw -ExceptionType ([System.FormatException]) -ExpectedMessage '*PLATFORM_PORT*'
        }
    }

    Context 'Test-PortInUse' {
        It 'sees a listener on the port, and a free port as free' {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $listener.Start()
            try {
                $busyPort = $listener.LocalEndpoint.Port
                Test-PortInUse -Port $busyPort | Should -BeTrue
            }
            finally {
                $listener.Stop()
            }
            Test-PortInUse -Port $busyPort | Should -BeFalse
        }
    }

    Context 'Get-ServiceUrls' {
        It 'gives HTTP URLs without the https overlay' {
            $urls = Get-ServiceUrls -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles)

            ($urls | Where-Object { $_.Name -eq 'Platform' }).Url | Should -Be 'http://localhost:8090'
        }

        It 'gives HTTPS URLs with the https mode file, and the storefront on its port' {
            $files = [string[]]@('docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml', 'docker-compose/frontend.yml')

            $urls = Get-ServiceUrls -EnvValues (New-PreflightEnv) -ComposeFiles $files

            ($urls | Where-Object { $_.Name -eq 'Platform' }).Url | Should -Be 'https://localhost:8090'
            ($urls | Where-Object { $_.Name -eq 'Storefront' }).Url | Should -Be 'https://localhost:443'
        }

        It 'lists Kibana only when its file is listed' {
            $without = Get-ServiceUrls -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles -Extra 'docker-compose/elasticsearch.yml')
            $with = Get-ServiceUrls -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles -Extra 'docker-compose/elasticsearch.yml', 'docker-compose/kibana.yml')

            $without.Name | Should -Not -Contain 'Kibana'
            ($with | Where-Object { $_.Name -eq 'Kibana' }).Url | Should -Be 'http://localhost:5601'
        }

        It 'lists the platform at PLATFORM_PORT whether it runs from source or is skipped (the user runs it)' {
            $files = [string[]]@('docker-compose.yml', 'docker-compose/postgres.yml')

            $source = Get-ServiceUrls -EnvValues (New-PreflightEnv @{ PLATFORM_SOURCE_PATH = '/src/vc-platform' }) -ComposeFiles $files
            $skipped = Get-ServiceUrls -EnvValues (New-PreflightEnv @{ SKIP_PLATFORM = 'true' }) -ComposeFiles $files

            ($source | Where-Object { $_.Name -eq 'Platform' }).Url | Should -Be 'http://localhost:8090'
            ($skipped | Where-Object { $_.Name -eq 'Platform' }).Url | Should -Be 'http://localhost:8090'
        }
    }

    Context 'ConvertTo-PublishedPorts' {
        It 'reads one JSON object per line (Compose 2.21 and later)' {
            $lines = @(
                '{"Name":"a-vc-db-1","Publishers":[{"URL":"127.0.0.1","TargetPort":5432,"PublishedPort":5432,"Protocol":"tcp"}]}'
                '{"Name":"a-vc-platform-web-1","Publishers":[{"URL":"127.0.0.1","TargetPort":8080,"PublishedPort":8090,"Protocol":"tcp"}]}'
            )

            $ports = ConvertTo-PublishedPorts -Json $lines

            $ports | Should -Be @(5432, 8090)
        }

        It 'reads one JSON array (older Compose)' {
            $text = '[{"Name":"a-vc-db-1","Publishers":[{"TargetPort":5432,"PublishedPort":5432}]},{"Name":"a-es-1","Publishers":[{"TargetPort":9200,"PublishedPort":9200}]}]'

            $ports = ConvertTo-PublishedPorts -Json $text

            $ports | Should -Be @(5432, 9200)
        }

        It 'ignores unpublished ports and containers without publishers' {
            $lines = @(
                '{"Name":"a-es-setup-1","Publishers":null}'
                '{"Name":"a-redis-1","Publishers":[{"TargetPort":6379,"PublishedPort":0}]}'
                ''
            )

            $ports = ConvertTo-PublishedPorts -Json $lines

            $ports.Count | Should -Be 0
        }
    }

    Context 'Get-DockerDaemonError' {
        BeforeEach {
            # The docker of these tests is a function, which the installed check does not count.
            Mock Test-DockerCommand { $true }
        }

        It 'returns $null when the daemon answers' {
            function docker { '29.0.0'; $global:LASTEXITCODE = 0 }

            Get-DockerDaemonError | Should -BeNullOrEmpty
        }

        It 'returns Docker''s message when the daemon does not answer' {
            function docker { Write-Error -Message 'permission denied while trying to connect to the docker API' -ErrorAction Continue; $global:LASTEXITCODE = 1 }

            Get-DockerDaemonError | Should -Match 'permission denied'
        }

        It 'names the missing command without running it' {
            Mock Test-DockerCommand { $false }
            function docker { throw 'docker must not run' }

            Get-DockerDaemonError | Should -Match 'not installed'
        }
    }

    Context 'Get-ProjectPublishedPorts' {
        It 'throws with Compose''s message when docker compose ps fails' {
            # A function shadows the docker executable inside this scope.
            function docker { Write-Error -Message 'service "vc-db" refers to undefined volume x' -ErrorAction Continue; $global:LASTEXITCODE = 15 }

            { Get-ProjectPublishedPorts -ComposeFiles 'docker-compose.yml' } | Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*undefined volume x*'
        }

        It 'returns each port once' {
            $lines = @('{"Publishers":[{"PublishedPort":8090},{"PublishedPort":8090}]}')

            $ports = ConvertTo-PublishedPorts -Json $lines

            $ports | Should -Be @(8090)
        }

        It 'reads the ports of the given files that exist, not the COMPOSE_FILE of .env, and ignores Compose''s warnings' {
            # The list start repairs: a hand-edited .env list may not load at all. docker-compose/platform-modules.yml is
            # generated after the preflight, so on a first run with module sources it is listed but not there yet.
            $folder = Join-Path $TestDrive "ports-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path (Join-Path $folder 'docker-compose') -Force
            foreach ($file in 'docker-compose.yml', 'docker-compose/postgres.yml') {
                Set-Content -LiteralPath (Join-Path $folder $file) -Value 'services: {}'
            }
            $script:dockerArguments = $null
            function docker {
                $script:dockerArguments = $args
                Write-Error -Message 'WARNING: the attribute version is obsolete' -ErrorAction Continue
                '{"Publishers":[{"PublishedPort":5432}]}'
                $global:LASTEXITCODE = 0
            }

            Push-Location -LiteralPath $folder
            try {
                $ports = Get-ProjectPublishedPorts -ComposeFiles 'docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/platform-modules.yml'
            }
            finally {
                Pop-Location
            }

            $ports | Should -Be @(5432)
            # --project-directory: with -f alone, the first file's folder would decide the project name and the .env read.
            ($script:dockerArguments -join ' ') | Should -BeExactly 'compose --project-directory . -f docker-compose.yml -f docker-compose/postgres.yml ps --format json'
        }

        It 'keeps a listed file that is missing, other than the generated one, so that Compose names it' {
            # A typo in COMPOSE_FILE, or a deleted file: dropping it would move the error to `up`, after start changed the folder.
            $folder = Join-Path $TestDrive "ports-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $folder -Force
            Set-Content -LiteralPath (Join-Path $folder 'docker-compose.yml') -Value 'services: {}'
            $script:dockerArguments = $null
            function docker {
                $script:dockerArguments = $args
                Write-Error -Message 'open docker-compose/postgress.yml: no such file or directory' -ErrorAction Continue
                $global:LASTEXITCODE = 14
            }

            Push-Location -LiteralPath $folder
            try {
                { Get-ProjectPublishedPorts -ComposeFiles 'docker-compose.yml', 'docker-compose/postgress.yml' } |
                    Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*postgress.yml: no such file*'
            }
            finally {
                Pop-Location
            }

            ($script:dockerArguments -join ' ') | Should -BeExactly 'compose --project-directory . -f docker-compose.yml -f docker-compose/postgress.yml ps --format json'
        }

        It 'returns no port, without asking Compose, when no file is left to load: <Label>' -ForEach @(
            # Without -f, Compose would fall back to the COMPOSE_FILE of .env.
            @{ Label = 'an empty list'; Files = [string[]]@() }
            @{ Label = 'only the generated file, not written yet'; Files = [string[]]@('docker-compose/platform-modules.yml') }
        ) {
            function docker { throw 'docker must not run' }

            Push-Location -LiteralPath $TestDrive
            try {
                $ports = Get-ProjectPublishedPorts -ComposeFiles $Files
            }
            finally {
                Pop-Location
            }

            @($ports).Count | Should -Be 0
        }
    }

    Context 'Get-MissingSolutionImages' {
        It 'lists the built images the files need that Docker does not have, and only those: <Label>' -ForEach @(
            @{ Label = 'the platform'; Absent = @('vc-platform:sl-latest'); Extra = @('docker-compose/frontend.yml'); Expected = @('vc-platform:sl-latest') }
            @{ Label = 'the storefront'; Absent = @('vc-frontend:sl-latest'); Extra = @('docker-compose/frontend.yml'); Expected = @('vc-frontend:sl-latest') }
            @{ Label = 'both'; Absent = 'vc-platform:sl-latest', 'vc-frontend:sl-latest'; Extra = @('docker-compose/frontend.yml'); Expected = 'vc-platform:sl-latest', 'vc-frontend:sl-latest' }
            @{ Label = 'none'; Absent = @(); Extra = @('docker-compose/frontend.yml'); Expected = @() }
        ) {
            # A function shadows the docker executable inside this scope. `docker image ls --quiet <image>` prints the
            # id of an image it has, nothing for one it lacks, and exits 0 for both (checked on Docker 29.9.3).
            # Any other call fails, as `docker image inspect` does for an image Docker lacks.
            $script:absentImages = $Absent
            function docker {
                if (($args[0..2] -join ' ') -cne 'image ls --quiet') {
                    Write-Error -Message "unexpected docker call: $args" -ErrorAction Continue
                    $global:LASTEXITCODE = 1
                    return
                }
                if ($script:absentImages -notcontains $args[-1]) { '12b1135f5f8b' }
                Write-Error -Message 'WARNING: a config warning on stderr' -ErrorAction Continue
                $global:LASTEXITCODE = 0
            }

            $missing = Get-MissingSolutionImages -ComposeFiles (New-PreflightFiles -Extra $Extra) -ProjectName 'sl'

            @($missing) | Should -Be $Expected
        }

        It 'asks for no image of a service that is not listed' {
            # Every image is missing to this docker: an image it was asked about would be listed.
            function docker { $global:LASTEXITCODE = 0 }

            $missing = Get-MissingSolutionImages -ComposeFiles ([string[]]@('docker-compose.yml', 'docker-compose/postgres.yml')) -ProjectName 'sl'

            @($missing).Count | Should -Be 0
        }

        It 'asks only for the storefront image when the platform does not run in Docker' {
            function docker { $global:LASTEXITCODE = 0 }

            $missing = Get-MissingSolutionImages -ComposeFiles ([string[]]@('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/frontend.yml')) -ProjectName 'sl'

            @($missing) | Should -Be @('vc-frontend:sl-latest')
        }

        It 'throws with Docker''s reason when Docker cannot answer, instead of calling the image missing' {
            function docker { Write-Error -Message 'request returned 500 Internal Server Error' -ErrorAction Continue; $global:LASTEXITCODE = 1 }

            { Get-MissingSolutionImages -ComposeFiles (New-PreflightFiles) -ProjectName 'sl' } |
                Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*vc-platform:sl-latest*500 Internal Server Error*'
        }
    }

    Context 'Get-KibanaPasswordWarning' {
        BeforeAll {
            $script:SecuredKibanaFiles = New-PreflightFiles -Extra 'docker-compose/https.yml', 'docker-compose/elasticsearch.yml', 'docker-compose/kibana.yml'
        }

        BeforeEach {
            Mock Start-Sleep { }
        }

        It 'warns for es-setup state "<EsSetupState>", naming its log' -ForEach @(
            # A new container is what runs es-setup again: stop removes it, and start creates it.
            @{ EsSetupState = 'failed'; Expected = '*gave up*docker compose logs es-setup*stop.ps1*start.ps1*' }
            @{ EsSetupState = 'pending'; Expected = '*not set the kibana_system password yet*docker compose logs es-setup*' }
        ) {
            Mock Invoke-DockerCompose { $EsSetupState; $global:LASTEXITCODE = 0 }

            Get-KibanaPasswordWarning -ComposeFiles $script:SecuredKibanaFiles -TimeoutSeconds 0 | Should -BeLike $Expected

            Should -Invoke Invoke-DockerCompose -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'exec' -and $args -contains 'es-setup' }
            Should -Invoke Start-Sleep -Times 0
        }

        It 'says nothing once the password is set' {
            Mock Invoke-DockerCompose { 'set'; $global:LASTEXITCODE = 0 }

            Get-KibanaPasswordWarning -ComposeFiles $script:SecuredKibanaFiles | Should -BeNullOrEmpty
        }

        It 'gives a pending record time to settle: es-setup sets the password a few seconds after `up` returns' {
            $script:kibanaStates = [System.Collections.Generic.Queue[string]]::new([string[]]@('pending', 'pending', 'set'))
            Mock Invoke-DockerCompose { $script:kibanaStates.Dequeue(); $global:LASTEXITCODE = 0 }

            Get-KibanaPasswordWarning -ComposeFiles $script:SecuredKibanaFiles | Should -BeNullOrEmpty

            Should -Invoke Invoke-DockerCompose -Times 3 -Exactly
            Should -Invoke Start-Sleep -Times 2 -Exactly
        }

        It 'does not wait on a record that is not pending (<EsSetupState>)' -ForEach @(
            @{ EsSetupState = 'failed' }
            @{ EsSetupState = 'set' }
        ) {
            Mock Invoke-DockerCompose { $EsSetupState; $global:LASTEXITCODE = 0 }

            $null = Get-KibanaPasswordWarning -ComposeFiles $script:SecuredKibanaFiles

            Should -Invoke Invoke-DockerCompose -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0
        }

        It 'reads only stdout: a Docker CLI warning on stderr is not part of the record' {
            Mock Invoke-DockerCompose { Write-Error -Message 'WARNING: Error loading config file' -ErrorAction Continue; 'set'; $global:LASTEXITCODE = 0 }

            Get-KibanaPasswordWarning -ComposeFiles $script:SecuredKibanaFiles | Should -BeNullOrEmpty
        }

        It 'warns with Compose''s reason when es-setup cannot be asked' {
            Mock Invoke-DockerCompose { Write-Error -Message 'service "es-setup" is not running' -ErrorAction Continue; $global:LASTEXITCODE = 1 }

            Get-KibanaPasswordWarning -ComposeFiles $script:SecuredKibanaFiles | Should -BeLike '*Could not check*es-setup*not running*'
        }

        It 'asks nothing without a secured Kibana (<Name>)' -TestCases @(
            @{ Name = 'HTTP mode'; Extra = @('docker-compose/elasticsearch.yml', 'docker-compose/kibana.yml') }
            @{ Name = 'no Kibana'; Extra = @('docker-compose/https.yml', 'docker-compose/elasticsearch.yml') }
        ) {
            param($Name, $Extra)
            Mock Invoke-DockerCompose { }

            Get-KibanaPasswordWarning -ComposeFiles (New-PreflightFiles -Extra $Extra) | Should -BeNullOrEmpty

            Should -Invoke Invoke-DockerCompose -Times 0
        }
    }

    Context 'Invoke-Preflight' {
        BeforeEach {
            Mock Test-DockerCommand { $true }
            Mock Get-DockerDaemonError { $null }
            Mock Get-ComposeVersion { '2.40.3' }
            Mock Get-ProjectPublishedPorts { [int[]]@() }
            Mock Test-PortInUse { $false }
        }

        It 'reports nothing when everything is in order' {
            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            @($errors).Count | Should -Be 0
        }

        It 'reports an old Compose and names the minimum' {
            Mock Get-ComposeVersion { '2.24.5' }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            ($errors -join "`n") | Should -Match '2\.24\.6'
        }

        It 'reports a missing Compose plugin' {
            Mock Get-ComposeVersion { throw [System.InvalidOperationException]::new('no compose') }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            ($errors -join "`n") | Should -Match 'Compose plugin'
        }

        It 'reports Docker not running, with Docker''s own reason, and says how to fix it' {
            Mock Get-DockerDaemonError { 'permission denied while trying to connect to the docker API at unix:///var/run/docker.sock' }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            ($errors -join "`n") | Should -Match 'Docker is not reachable'
            ($errors -join "`n") | Should -Match 'permission denied'
            ($errors -join "`n") | Should -Match 'Start Docker'
        }

        It 'prints Docker''s reason without doubling its punctuation' {
            Mock Get-DockerDaemonError { 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            ($errors -join "`n") | Should -Not -Match '\?\.'
            # Docker's reason comes last, as Docker wrote it.
            $errors[0] | Should -Match 'Docker says: Cannot connect.*\?$'
        }

        It 'reports a missing docker command once, with the install advice, and asks neither the daemon nor Compose' {
            Mock Test-DockerCommand { $false }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true -ProjectName 'sl'

            @($errors).Count | Should -Be 1
            $errors[0] | Should -Match "'docker' command is not installed"
            $errors[0] | Should -Match 'Install Docker with Compose 2\.24\.6 or later \(https://docs\.docker\.com/compose/install/\)'
            # Starting a daemon is not the fix, and the sentence is the scripts' own, not Docker's.
            $errors[0] | Should -Not -Match 'Start Docker|Docker says'
            Should -Invoke Get-ComposeVersion -Times 0
            Should -Invoke Get-DockerDaemonError -Times 0
            Should -Invoke Get-ProjectPublishedPorts -Times 0
        }

        It 'still checks the Compose version when Docker is installed but its daemon is down' {
            Mock Get-DockerDaemonError { 'Cannot connect to the Docker daemon' }
            Mock Get-ComposeVersion { '2.24.5' }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            ($errors -join "`n") | Should -Match '2\.24\.6'
            ($errors -join "`n") | Should -Match 'Docker is not reachable'
            Should -Invoke Get-ComposeVersion -Times 1 -Exactly
        }

        It 'passes the file list it checks to the published-ports query' {
            Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true | Out-Null

            Should -Invoke Get-ProjectPublishedPorts -Times 1 -Exactly -ParameterFilter { ($ComposeFiles -join ';') -eq ((New-PreflightFiles) -join ';') }
        }

        It 'stops at the .env value errors and runs no other check' {
            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv @{ DB_PASSWORD = 'a$b' }) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            ($errors -join "`n") | Should -Match 'DB_PASSWORD'
            Should -Invoke Get-ComposeVersion -Times 0
            Should -Invoke Get-DockerDaemonError -Times 0
            Should -Invoke Get-ProjectPublishedPorts -Times 0
        }

        It 'names ./build.ps1 for an image the folder builds that Docker does not have (a build that failed after a migration)' {
            Mock Get-MissingSolutionImages { [string[]]@('vc-platform:sl-latest') }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true -ProjectName 'sl'

            @($errors).Count | Should -Be 1
            $errors[0] | Should -Match 'vc-platform:sl-latest'
            $errors[0] | Should -Match '\./build\.ps1'
            Should -Invoke Get-MissingSolutionImages -Times 1 -Exactly -ParameterFilter { $ProjectName -eq 'sl' }
        }

        It 'reports Docker''s reason, not a missing image, when Docker cannot list the images' {
            Mock Get-MissingSolutionImages { throw [System.InvalidOperationException]::new("'docker image ls vc-platform:sl-latest' failed: request returned 500 Internal Server Error") }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true -ProjectName 'sl'

            @($errors).Count | Should -Be 1
            $errors[0] | Should -Match '500 Internal Server Error'
            $errors[0] | Should -Not -Match 'does not exist|build\.ps1'
        }

        It 'checks no image without a project name, or when Docker is not reachable' {
            Mock Get-MissingSolutionImages { [string[]]@('vc-platform:sl-latest') }

            $null = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true
            Mock Get-DockerDaemonError { 'down' }
            $null = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true -ProjectName 'sl'

            Should -Invoke Get-MissingSolutionImages -Times 0
        }

        It 'applies the ADMIN_PASSWORD rule only to a non-interactive run' {
            $values = New-PreflightEnv @{ ADMIN_PASSWORD = 'store' }

            $interactiveErrors = Invoke-Preflight -EnvValues $values -ComposeFiles (New-PreflightFiles) -NonInteractive $false
            @($interactiveErrors).Count | Should -Be 0
            (Invoke-Preflight -EnvValues $values -ComposeFiles (New-PreflightFiles) -NonInteractive $true) -join "`n" | Should -Match 'ADMIN_PASSWORD'
        }

        It 'reports a busy port with its .env key' {
            Mock Test-PortInUse { $Port -eq 8090 }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            @($errors).Count | Should -Be 1
            $errors[0] | Should -Match '8090'
            $errors[0] | Should -Match 'PLATFORM_PORT'
        }

        It 'does not flag the ports the stack publishes itself (a re-run on a running stack)' {
            Mock Get-ProjectPublishedPorts { [int[]]@(5432, 8090) }
            Mock Test-PortInUse { $Port -in 5432, 8090 }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $false

            @($errors).Count | Should -Be 0
        }

        It 'reports Compose''s own error, not busy ports, when Compose cannot read the project' {
            Mock Get-ProjectPublishedPorts { throw [System.InvalidOperationException]::new("'docker compose ps' failed: required variable DB_PASSWORD is missing a value") }
            Mock Test-PortInUse { $Port -in 5432, 8090 }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            ($errors -join "`n") | Should -Match 'DB_PASSWORD is missing a value'
            ($errors -join "`n") | Should -Not -Match 'already in use'
        }

        It 'checks only the ports of the listed services' {
            Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true | Out-Null

            Should -Invoke Test-PortInUse -Times 1 -ParameterFilter { $Port -eq 5432 }
            Should -Invoke Test-PortInUse -Times 1 -ParameterFilter { $Port -eq 8090 }
            Should -Invoke Test-PortInUse -Times 0 -ParameterFilter { $Port -eq 6379 }
        }

        It 'names the required .env keys that are empty in a non-interactive run (start needs COMPOSE_FILE only)' {
            $values = New-PreflightEnv @{ COMPOSE_FILE = ''; RELEASE_CHANNEL = '' }

            # What start passes for an empty COMPOSE_FILE: the normalized empty list.
            $errors = Invoke-Preflight -EnvValues $values -ComposeFiles ([string[]]@('docker-compose.yml')) -NonInteractive $true

            @($errors).Count | Should -Be 1
            $errors[0] | Should -Match 'COMPOSE_FILE is empty in \.env'
            ($errors -join "`n") | Should -Not -Match 'RELEASE_CHANNEL'
            # First and alone: no other check runs.
            Should -Invoke Get-DockerDaemonError -Times 0
            Should -Invoke Get-ComposeVersion -Times 0
            Should -Invoke Get-ProjectPublishedPorts -Times 0
        }

        It 'leaves the required keys to the prompts in an interactive run' {
            $values = New-PreflightEnv @{ RELEASE_CHANNEL = '' }

            $errors = Invoke-Preflight -EnvValues $values -ComposeFiles (New-PreflightFiles) -NonInteractive $false

            @($errors).Count | Should -Be 0
        }
    }
}

Describe 'Source platform preflight' -Tag 'Unit' {
    BeforeAll {
        function script:New-SourcePlatformFolder {
            param([switch]$Built, [ValidateSet('checkout', 'prebuilt')][string]$Kind = 'checkout')

            $folder = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) 'platform'
            if ($Kind -eq 'checkout') {
                $web = Join-Path $folder 'src/VirtoCommerce.Platform.Web'
                $null = New-Item -ItemType Directory -Path $web -Force
                Set-Content -LiteralPath (Join-Path $web 'VirtoCommerce.Platform.Web.csproj') -Value '<Project />'
                if ($Built) {
                    $null = New-Item -ItemType Directory -Path (Join-Path $web 'bin/Debug') -Force
                    Set-Content -LiteralPath (Join-Path $web 'bin/Debug/VirtoCommerce.Platform.Web.dll') -Value 'x'
                }
            }
            else {
                $null = New-Item -ItemType Directory -Path $folder -Force
                if ($Built) {
                    Set-Content -LiteralPath (Join-Path $folder 'VirtoCommerce.Platform.Web.dll') -Value 'x'
                }
            }
            $folder
        }

        function script:New-SourceEnv {
            param([string]$PlatformPath, [hashtable]$Override = @{})

            $values = [ordered]@{
                COMPOSE_FILE         = 'docker-compose.yml;docker-compose/postgres.yml'
                RELEASE_CHANNEL      = 'stable'
                PLATFORM_SOURCE_PATH = $PlatformPath
                PLATFORM_PORT        = '8090'
                PGSQL_PORT           = '5432'
            }
            foreach ($key in $Override.Keys) {
                $values[$key] = $Override[$key]
            }
            $values
        }

        $script:sourceStack = [string[]]@('docker-compose.yml', 'docker-compose/postgres.yml')
    }

    BeforeEach {
        Mock Test-DockerCommand { $true }
        Mock Get-DockerDaemonError { $null }
        Mock Get-ComposeVersion { '2.40.3' }
        Mock Get-ProjectPublishedPorts { [int[]]@() }
        Mock Test-PortInUse { $false }
        Mock Test-FileSharing { $true }
        Mock Get-RunningSourcePlatform { $null }
        Mock Test-SymlinkRights { $true }
    }

    It 'reports a missing build output and names the folder' {
        $path = New-SourcePlatformFolder

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

        @($errors).Count | Should -Be 1
        $errors[0] | Should -BeLike "*$(Join-Path $path 'src/VirtoCommerce.Platform.Web')*"
        $errors[0] | Should -Match 'build'
    }

    It 'reports a folder that is neither a checkout nor a prebuilt platform, and names it' {
        $path = New-SourcePlatformFolder -Kind prebuilt

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

        @($errors).Count | Should -Be 1
        $errors[0] | Should -BeLike "*$path*"
        $errors[0] | Should -Match 'PLATFORM_SOURCE_PATH'
    }

    It 'reports nothing for a built checkout and a prebuilt folder' {
        foreach ($kind in 'checkout', 'prebuilt') {
            $path = New-SourcePlatformFolder -Kind $kind -Built

            $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

            @($errors).Count | Should -Be 0
        }
    }

    It 'asks for no build output when SKIP_PLATFORM=true' {
        $path = New-SourcePlatformFolder

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path @{ SKIP_PLATFORM = 'true' }) -ComposeFiles $script:sourceStack -NonInteractive $true

        @($errors).Count | Should -Be 0
    }

    It 'checks nothing about a source platform for a Docker platform' {
        $files = [string[]]@('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml')

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv '') -ComposeFiles $files -NonInteractive $true

        @($errors).Count | Should -Be 0
    }

    It 'does not flag the port of the source platform that this folder started itself' {
        $path = New-SourcePlatformFolder -Built
        Mock Get-RunningSourcePlatform { [System.Diagnostics.Process]::GetCurrentProcess() }
        Mock Test-PortInUse { $Port -eq 8090 }

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

        @($errors).Count | Should -Be 0
    }

    It 'still flags the port when no source platform of this folder runs' {
        $path = New-SourcePlatformFolder -Built
        Mock Test-PortInUse { $Port -eq 8090 }

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

        @($errors).Count | Should -Be 1
        $errors[0] | Should -Match 'PLATFORM_PORT'
    }

    Context 'symlink rights for the module links' {
        It 'asks for Developer Mode or an elevated shell when links are planned and cannot be made' {
            $path = New-SourcePlatformFolder -Built
            $web = New-ModuleFolder 'A.Web' 'VirtoCommerce.A'
            Mock Test-SymlinkRights { $false }

            $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path @{ MODULE_SOURCE_PATHS = $web }) -ComposeFiles $script:sourceStack -NonInteractive $true

            @($errors).Count | Should -Be 1
            $errors[0] | Should -Match 'Developer Mode or run an elevated shell'
        }

        It 'does not ask without module sources, even where links cannot be made' {
            $path = New-SourcePlatformFolder -Built
            Mock Test-SymlinkRights { $false }

            $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

            @($errors).Count | Should -Be 0
            Should -Invoke Test-SymlinkRights -Times 0
        }

        It 'does not ask when the platform runs in Docker (the sources are bind-mounted)' {
            $web = New-ModuleFolder 'A.Web' 'VirtoCommerce.A'
            $files = [string[]]@('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml')
            Mock Test-SymlinkRights { $false }

            $errors = Invoke-Preflight -EnvValues (New-SourceEnv '' @{ MODULE_SOURCE_PATHS = $web }) -ComposeFiles $files -NonInteractive $true

            @($errors).Count | Should -Be 0
        }
    }
}
