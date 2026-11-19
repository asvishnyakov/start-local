# Renders the storefront nginx templates the way the vc-frontend image does and runs `nginx -t` on the result, in a
# throwaway container of the Dockerfile's base image. The templates go in through stdin (quoted heredocs), so no bind
# mount and no Docker Desktop File Sharing is involved (FC §14). The environment is what `docker compose config` gives
# vc-frontend, so the templates are checked against the compose files as they are. Needs a Docker daemon.
BeforeDiscovery {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:hasDaemon = -not (Get-DockerDaemonError)

    $script:cases = foreach ($https in $false, $true) {
        foreach ($platform in $true, $false) {
            $requested = @('docker-compose.yml') + @(if ($https) { 'docker-compose/https.yml' }) + @('docker-compose/postgres.yml') +
                @(if ($platform) { 'docker-compose/platform.yml' }) + @('docker-compose/frontend.yml')
            @{
                Label     = "$(if ($https) { 'https' } else { 'http' }), $(if ($platform) { 'Docker platform' } else { 'host platform' })"
                Requested = [string[]]$requested
                Https     = $https
            }
        }
    }
}

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    $script:FrontendFolder = Join-Path (Get-TestRepositoryRoot) 'frontend'
    $script:Dockerfile = Get-Content -LiteralPath (Join-Path $script:FrontendFolder 'Dockerfile')

    function script:Get-NginxBaseImage {
        $from = $script:Dockerfile | Where-Object { $_ -match '^\s*FROM\s+(\S+)' } | Select-Object -First 1
        if (-not $from -or $from -notmatch '^\s*FROM\s+(\S+)') {
            throw [System.InvalidOperationException]::new('frontend/Dockerfile has no FROM line.')
        }
        $Matches[1]
    }

    function script:Get-TemplateFiles {
        # The files the Dockerfile copies into /etc/nginx: @{ Destination; Source } for each, from its COPY lines.
        foreach ($line in $script:Dockerfile) {
            if ($line -notmatch '^\s*COPY\s+\./(?<source>nginx/\S*)\s+(?<destination>/etc/nginx/\S+)\s*$') {
                continue
            }
            $sourceFolder = Join-Path $script:FrontendFolder $Matches['source']
            $destinationFolder = $Matches['destination'].TrimEnd('/')
            foreach ($file in Get-ChildItem -LiteralPath $sourceFolder -File -Recurse) {
                $relative = [System.IO.Path]::GetRelativePath($sourceFolder, $file.FullName).Replace('\', '/')
                @{ Destination = "$destinationFolder/$relative"; Source = $file.FullName }
            }
        }
    }

    function script:New-DevCertificatePem {
        # A throwaway self-signed localhost certificate, as PEM text: @{ Certificate; Key }.
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        try {
            $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                'CN=localhost', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
            @{ Certificate = $certificate.ExportCertificatePem(); Key = $rsa.ExportPkcs8PrivateKeyPem() }
        }
        finally {
            $rsa.Dispose()
        }
    }

    function script:ConvertTo-HeredocCommand {
        # A shell command that writes $Content to $Path through a quoted heredoc: nothing in it is expanded.
        param([string]$Path, [string]$Content)
        $text = $Content -replace "`r`n", "`n"
        if ($text.Contains("`nSL_EOF`n")) {
            throw [System.InvalidOperationException]::new("The content for $Path holds the heredoc terminator.")
        }
        "mkdir -p '$(Split-Path -Parent $Path)'`ncat > '$Path' <<'SL_EOF'`n$($text.TrimEnd("`n"))`nSL_EOF"
    }

    function script:Invoke-NginxTemplateCheck {
        # Renders the templates with $Environment through the image's own entrypoint and runs `nginx -t`.
        # Returns @{ ExitCode; Output; Rendered } where Rendered is the rendered storefront snippet.
        param([Parameter(Mandatory)][hashtable]$Environment, [bool]$Https)

        $commands = [System.Collections.Generic.List[string]]::new()
        $commands.Add('set -e')
        foreach ($template in Get-TemplateFiles) {
            $commands.Add((ConvertTo-HeredocCommand -Path $template.Destination -Content (Get-Content -LiteralPath $template.Source -Raw)))
        }
        if ($Https) {
            $pem = New-DevCertificatePem
            $commands.Add((ConvertTo-HeredocCommand -Path '/certs/dev/localhost.pem' -Content $pem.Certificate))
            $commands.Add((ConvertTo-HeredocCommand -Path '/certs/dev/localhost.key' -Content $pem.Key))
        }
        # The image's entrypoint runs /docker-entrypoint.d/ (20-envsubst-on-templates.sh renders the templates) for an
        # nginx command; `nginx -t` then parses the result.
        $commands.Add('/docker-entrypoint.sh nginx -t')
        $commands.Add('echo SL_RENDERED_SNIPPET')
        $commands.Add('cat /etc/nginx/conf.d/snippets/storefront.conf')
        $commands.Add('echo SL_RENDERED_SERVER')
        $commands.Add('cat /etc/nginx/conf.d/default.conf')
        $shellScript = ($commands -join "`n") + "`n"

        $environmentArguments = foreach ($name in $Environment.Keys) { '-e'; "$name=$($Environment[$name])" }
        # nginx -t resolves the proxy_pass hosts; the compose network is not there, so both upstreams resolve to loopback.
        $hostArguments = '--add-host', 'vc-platform-web:127.0.0.1', '--add-host', 'host.docker.internal:127.0.0.1'
        $output = $shellScript | & docker run --rm -i @hostArguments @environmentArguments --entrypoint sh (Get-NginxBaseImage) -s 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($output | ForEach-Object { "$_" }) -join "`n"
        $snippet = if ($text -match '(?s)SL_RENDERED_SNIPPET\n(?<snippet>.*)SL_RENDERED_SERVER\n(?<server>.*)$') { $Matches['snippet'] } else { '' }
        $server = if ($text -match '(?s)SL_RENDERED_SERVER\n(?<server>.*)$') { $Matches['server'] } else { '' }
        @{ ExitCode = $exitCode; Output = $text; Rendered = $snippet; Server = $server }
    }
}

Describe 'Storefront nginx templates' -Tag 'Compose' -Skip:(-not $script:hasDaemon) {
    It 'the Dockerfile copies the http, https and common templates' {
        $destinations = @(Get-TemplateFiles | ForEach-Object { $_.Destination })

        $destinations | Should -Contain '/etc/nginx/templates-http/default.conf.template'
        $destinations | Should -Contain '/etc/nginx/templates-https/default.conf.template'
        $destinations | Should -Contain '/etc/nginx/templates-http/snippets/storefront.conf.template'
        $destinations | Should -Contain '/etc/nginx/templates-https/snippets/storefront.conf.template'
    }

    Context '<Label>' -ForEach $script:cases {
        BeforeAll {
            [string[]]$composeFiles = Update-ComposeFileList -ComposeFiles $Requested -HasSourceModules $false
            $folder = New-ComposeFixtureFolder -ComposeFiles $composeFiles
            try {
                $config = Invoke-ComposeConfigJson $folder
            }
            finally {
                Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
            }
            $script:environment = @{}
            foreach ($variable in $config.services.'vc-frontend'.environment.PSObject.Properties) {
                $script:environment[$variable.Name] = [string]$variable.Value
            }
            $script:result = Invoke-NginxTemplateCheck -Environment $script:environment -Https $Https
        }

        It 'compose gives vc-frontend the template directory, the scheme and the upstream' {
            $script:environment['NGINX_ENVSUBST_TEMPLATE_DIR'] | Should -BeExactly $(if ($Https) { '/etc/nginx/templates-https' } else { '/etc/nginx/templates-http' })
            $script:environment['PLATFORM_SCHEME'] | Should -BeExactly $(if ($Https) { 'https' } else { 'http' })
            $script:environment['PLATFORM_UPSTREAM'] | Should -Not -BeNullOrEmpty
        }

        It 'nginx -t accepts the rendered configuration' {
            $script:result.ExitCode | Should -Be 0 -Because $script:result.Output
            $script:result.Output | Should -Match 'syntax is ok'
            $script:result.Output | Should -Match 'test is successful'
        }

        It 'every PLATFORM_ variable is substituted and the nginx variables are left alone' {
            $script:result.Rendered | Should -Not -BeNullOrEmpty -Because $script:result.Output
            $script:result.Rendered | Should -Not -Match '\$\{'
            $script:result.Rendered | Should -Match ([regex]::Escape('try_files $uri $uri/ /index.html;'))
            $script:result.Rendered | Should -Match ([regex]::Escape('proxy_set_header Host $host;'))
            $script:result.Rendered | Should -Match ([regex]::Escape('proxy_set_header Upgrade $http_upgrade;'))
        }

        It 'every proxy_pass goes to the compose upstream over the mode''s scheme' {
            $expected = "$($script:environment['PLATFORM_SCHEME'])://$($script:environment['PLATFORM_UPSTREAM'])"
            $targets = @([regex]::Matches($script:result.Rendered, '(?m)^\s*proxy_pass\s+(?<target>[^;]+);') | ForEach-Object { $_.Groups['target'].Value })

            $targets.Count | Should -BeGreaterThan 0
            foreach ($target in $targets) {
                $target | Should -BeExactly $expected
            }
        }

        It 'the server block listens on 8080, with TLS in HTTPS mode only' {
            if ($Https) {
                $script:result.Server | Should -Match '(?m)^\s*listen\s+8080 ssl;'
                $script:result.Server | Should -Match ([regex]::Escape('ssl_certificate     /certs/dev/localhost.pem;'))
            }
            else {
                $script:result.Server | Should -Match '(?m)^\s*listen\s+8080;'
                $script:result.Server | Should -Not -Match 'ssl'
            }
        }
    }
}
