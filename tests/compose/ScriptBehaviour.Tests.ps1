# The shell the compose files hand to containers, run on this machine against stand-ins: the platform health checks
# (only a 200 reply is healthy) and es-setup's kibana_system loop (gives up after 120 attempts, records the outcome).
# The commands come from `docker compose config`, so an escaping slip in the YAML shows here and not only in the smoke
# tier. Needs bash, plus openssl and python3 for the health checks. It runs only off Windows: the commands are written
# for a Linux container's shell.
# The stand-in platform is a few lines of Python: it answers GET /health with the status in its status file, over plain
# HTTP or over TLS with a self-signed certificate.
BeforeDiscovery {
    $script:hasTools = -not $IsWindows -and [bool](Get-Command docker -ErrorAction SilentlyContinue) -and
        [bool](Get-Command bash -ErrorAction SilentlyContinue)
    $script:hasServers = $script:hasTools -and [bool](Get-Command openssl -ErrorAction SilentlyContinue) -and
        [bool](Get-Command python3 -ErrorAction SilentlyContinue)
}

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    # The service's command or health check as Compose renders it, with Compose's $$ escape undone (what the
    # container's shell receives).
    function script:Get-RenderedShell {
        param([Parameter(Mandatory)][string[]]$ComposeFiles, [Parameter(Mandatory)][string]$Service, [switch]$HealthCheck)
        $folder = New-ComposeFixtureFolder -ComposeFiles $ComposeFiles
        try {
            $rendered = (Invoke-ComposeConfigJson $folder).services.$Service
            $text = if ($HealthCheck) { $rendered.healthcheck.test[-1] } else { $rendered.command[-1] }
            $text.Replace('$$', '$')
        }
        finally {
            Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function script:Get-FreePort {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try { $listener.LocalEndpoint.Port } finally { $listener.Stop() }
    }

    # Starts a server in $Root and waits until it accepts connections. Returns the process.
    function script:Start-StandIn {
        param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][int]$Port)
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $Root -PassThru `
            -RedirectStandardOutput (Join-Path $Root 'server.out') -RedirectStandardError (Join-Path $Root 'server.err')
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $deadline) {
            $client = [System.Net.Sockets.TcpClient]::new()
            try {
                $client.Connect([System.Net.IPAddress]::Loopback, $Port)
                return $process
            }
            catch [System.Net.Sockets.SocketException] {
                Start-Sleep -Milliseconds 100
            }
            finally {
                $client.Dispose()
            }
        }
        $process.Kill()
        throw [System.InvalidOperationException]::new("The stand-in server '$FilePath' did not listen on port ${Port}: $(Get-Content -LiteralPath (Join-Path $Root 'server.err') -Raw -ErrorAction Ignore)")
    }

    # Runs the health check, pointed at $Port instead of the container's PLATFORM_PORT (the fixture's .env has the
    # standard one), and returns bash's exit code.
    function script:Invoke-HealthCheck {
        param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][int]$Port)
        $containerPort = Get-PortDefault 'PLATFORM_PORT'
        $null = & bash -c $Command.Replace("127.0.0.1:$containerPort", "127.0.0.1:$Port").Replace("127.0.0.1/$containerPort", "127.0.0.1/$Port") 2>&1
        $LASTEXITCODE
    }
}

Describe 'Platform health checks' -Tag 'Compose' -Skip:(-not $script:hasServers) {
    BeforeAll {
        $script:Root = Join-Path (Get-TestScratchRoot) "sl-health-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $script:Root
        $script:Port = Get-FreePort
        $script:StatusFile = Join-Path $script:Root 'status'
        Set-Content -LiteralPath (Join-Path $script:Root 'server.py') -Value @'
import http.server, ssl, sys
port, status_file, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_GET(self):
        status = int(open(status_file).read().strip())
        body = b'Healthy' if status == 200 else b'Unhealthy'
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(('127.0.0.1', port), Handler)
if cert != '-':
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
'@
        $null = & openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' -keyout (Join-Path $script:Root 'key.pem') -out (Join-Path $script:Root 'cert.pem') 2>&1
        Assert-NativeSuccess 'openssl req'

        # Runs the check against the stand-in for each status; returns the exit codes by status.
        function script:Get-CheckResults {
            param([Parameter(Mandatory)][string]$Check, [switch]$Tls)
            # '-' for no TLS: Start-Process drops an empty argument.
            $tlsArguments = if ($Tls) { 'cert.pem', 'key.pem' } else { '-', '-' }
            Set-Content -LiteralPath $script:StatusFile -Value '200'
            $server = Start-StandIn -FilePath 'python3' -Arguments (@('server.py', $script:Port, 'status') + $tlsArguments) -Root $script:Root -Port $script:Port
            try {
                $results = [ordered]@{}
                foreach ($status in 200, 503, 404) {
                    Set-Content -LiteralPath $script:StatusFile -Value $status
                    $results[[string]$status] = Invoke-HealthCheck -Command $Check -Port $script:Port
                }
                $results
            }
            finally {
                $server.Kill()
                $server.WaitForExit()
            }
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context '<Mode>' -ForEach @(
        @{ Mode = 'HTTP mode (bash /dev/tcp)'; Tls = $false; Files = @('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml') }
        @{ Mode = 'HTTPS mode (openssl s_client, unverified self-signed certificate)'; Tls = $true; Files = @('docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml', 'docker-compose/platform.https.yml') }
    ) {
        BeforeAll {
            $script:Check = Get-RenderedShell -ComposeFiles $Files -Service 'vc-platform-web' -HealthCheck
        }

        It 'is unhealthy while nothing listens' {
            Invoke-HealthCheck -Command $script:Check -Port $script:Port | Should -Not -Be 0
        }

        It 'is healthy for 200 only' {
            $results = Get-CheckResults -Check $script:Check -Tls:$Tls

            $results['200'] | Should -Be 0
            $results['503'] | Should -Not -Be 0
            $results['404'] | Should -Not -Be 0
        }
    }
}

Describe 'es-setup kibana_system loop' -Tag 'Compose' -Skip:(-not $script:hasTools) {
    BeforeAll {
        $script:SecuredKibanaFiles = [string[]]@('docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/elasticsearch.yml', 'docker-compose/elasticsearch.https.yml', 'docker-compose/kibana.yml')
        $command = Get-RenderedShell -ComposeFiles ($script:SecuredKibanaFiles -ne 'docker-compose/kibana.yml') -Service 'es-setup'
        # The reset of the outcome record, then the password step up to the new record; the rest needs the
        # Elasticsearch image.
        $lines = $command -split "`n"
        $reset = [array]::FindIndex($lines, [Predicate[string]] { param($line) $line -like 'rm -f /tmp/kibana-password-*' })
        $wait = [array]::FindIndex($lines, [Predicate[string]] { param($line) $line -like 'echo "Waiting for Elasticsearch"' })
        $first = [array]::FindIndex($lines, [Predicate[string]] { param($line) $line -like 'attempt=0' })
        $last = [array]::FindIndex($lines, [Predicate[string]] { param($line) $line -like '*touch /tmp/kibana-password-failed*' })
        $reset | Should -BeGreaterOrEqual 0
        # Before the wait for Elasticsearch: a restarted container keeps its /tmp, and until the reset start.ps1 would
        # read the last run's outcome.
        $wait | Should -BeGreaterThan $reset
        $first | Should -BeGreaterThan $wait
        $last | Should -BeGreaterThan $first
        $script:Loop = (@($lines[$reset]) + $lines[$first..$last]) -join "`n"
        $script:Root = Join-Path (Get-TestScratchRoot) "sl-es-setup-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $script:Root
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'records <Expected> after <Attempts> curl call(s) when Elasticsearch accepts the password <Accepts>, and start.ps1 reads that record' -TestCases @(
        @{ Accepts = 'at once'; SucceedsOnCall = 1; Attempts = 1; Expected = 'kibana-password-set' }
        # The last attempt the loop makes still counts.
        @{ Accepts = 'on the last attempt'; SucceedsOnCall = 120; Attempts = 120; Expected = 'kibana-password-set' }
        @{ Accepts = 'never'; SucceedsOnCall = 0; Attempts = 120; Expected = 'kibana-password-failed' }
    ) {
        param($Accepts, $SucceedsOnCall, $Attempts, $Expected)
        $folder = Join-Path $script:Root ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $folder
        # The records of an earlier run of the same container: the reset must clear both.
        foreach ($staleRecord in 'kibana-password-set', 'kibana-password-failed') {
            $null = New-Item -ItemType File -Path (Join-Path $folder $staleRecord)
        }
        # curl and sleep are stubbed, and the records go to the scratch folder instead of /tmp. curl counts its calls and
        # answers {} (the password is set) from call SucceedsOnCall on; 0 means never.
        $curlStub = "curl() { echo x >> '$folder/calls'; if [ $SucceedsOnCall -gt 0 ] && [ `$(wc -l < '$folder/calls') -ge $SucceedsOnCall ]; then echo '{}'; else echo '{`"error`":`"unauthorized`"}'; fi; }"
        $shellScript = "$curlStub`nsleep() { :; }`n" + $script:Loop.Replace('/tmp/', "$folder/")

        $output = & bash -c $shellScript 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0 -Because $output
        @(Get-ChildItem -LiteralPath $folder -Filter 'kibana-password-*' | ForEach-Object { $_.Name }) | Should -Be @($Expected)
        @(Get-Content -LiteralPath (Join-Path $folder 'calls')).Count | Should -Be $Attempts
        if ($Expected -like '*failed') {
            $output | Should -Match 'Gave up setting the kibana_system password'
            # Every 12th attempt logs the last reply.
            ([regex]::Matches($output, 'Still setting the kibana_system password')).Count | Should -Be 10
        }

        # The reader of start.ps1, run here against the records the loop just wrote: both sides name the same files.
        Mock Invoke-DockerCompose { & bash -c ($args[-1].Replace('/tmp/', "$folder/")) }
        $warning = Get-KibanaPasswordWarning -ComposeFiles $script:SecuredKibanaFiles -TimeoutSeconds 0
        if ($Expected -like '*failed') {
            $warning | Should -BeLike '*gave up*'
        }
        else {
            $warning | Should -BeNullOrEmpty
        }
    }

    It 'reads a run that has recorded nothing yet as pending' {
        $folder = Join-Path $script:Root ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $folder
        Mock Invoke-DockerCompose { & bash -c ($args[-1].Replace('/tmp/', "$folder/")) }

        Get-KibanaPasswordWarning -ComposeFiles $script:SecuredKibanaFiles -TimeoutSeconds 0 | Should -BeLike '*not set the kibana_system password yet*'
    }
}
