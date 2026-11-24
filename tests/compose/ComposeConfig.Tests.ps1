BeforeDiscovery {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)

    # 3 providers x platform/storefront (none, platform, platform + storefront, storefront on a host platform)
    # x Elasticsearch on/off x Kibana (with Elasticsearch only) x Redis on/off x es-limited (with Elasticsearch only),
    # in HTTP and in HTTPS mode.
    $script:stacks = [ordered]@{
        none               = @()
        platform           = @('platform')
        'platform+frontend' = @('platform', 'frontend')
        frontend           = @('frontend')
    }
    $script:cases = foreach ($https in $false, $true) {
    foreach ($provider in 'postgres', 'mysql', 'sqlserver') {
        foreach ($stack in $script:stacks.Keys) {
            foreach ($elasticsearch in $false, $true) {
                foreach ($kibana in ($(if ($elasticsearch) { $false, $true } else { $false }))) {
                    foreach ($esLimited in ($(if ($elasticsearch) { $false, $true } else { $false }))) {
                        foreach ($redis in $false, $true) {
                            $requested = [System.Collections.Generic.List[string]]::new()
                            $requested.Add('docker-compose.yml')
                            if ($https) {
                                $requested.Add('docker-compose/https.yml')
                            }
                            $requested.Add("docker-compose/$provider.yml")
                            $features = [ordered]@{ elasticsearch = $elasticsearch; kibana = $kibana; redis = $redis; 'es-limited' = $esLimited }
                            foreach ($feature in $script:stacks[$stack]) {
                                $features[$feature] = $true
                            }
                            foreach ($feature in $features.Keys) {
                                if ($features[$feature]) {
                                    $requested.Add("docker-compose/$feature.yml")
                                }
                            }
                            $label = (@($provider) + @($features.Keys | Where-Object { $features[$_] }) + @(if ($https) { 'https' })) -join '+'
                            $normalized = [string[]](Update-ComposeFileList -ComposeFiles $requested.ToArray() -HasSourceModules $false)
                            $composeFiles = $normalized
                            @{
                                Label         = $label
                                Https         = $https
                                Provider      = $provider
                                Platform      = $script:stacks[$stack] -contains 'platform'
                                Frontend      = $script:stacks[$stack] -contains 'frontend'
                                Elasticsearch = $elasticsearch
                                Kibana        = $kibana
                                Redis         = $redis
                                EsLimited     = $esLimited
                                ComposeFiles  = $composeFiles
                            }
                        }
                    }
                }
            }
        }
    }
    }
    $script:providerVolume = @{ postgres = 'postgres_data'; mysql = 'mysql_data'; sqlserver = 'mssql_data' }
}

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    function script:Get-PublishedPorts {
        param($Config)
        foreach ($service in $Config.services.PSObject.Properties.Value) {
            foreach ($port in $service.ports) {
                $port
            }
        }
    }
}

Describe 'Compose config' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    Context '<Label>' -ForEach $script:cases {
        BeforeAll {
            $script:folders = [System.Collections.Generic.List[string]]::new()
            $folder = New-ComposeFixtureFolder -ComposeFiles $ComposeFiles
            $script:folders.Add($folder)
            $script:configError = $null
            $script:config = $null
            try {
                $script:config = Invoke-ComposeConfigJson $folder
            }
            catch {
                $script:configError = $_.Exception.Message
            }
        }

        AfterAll {
            foreach ($folder in $script:folders) {
                Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'config succeeds' {
            $script:configError | Should -BeNullOrEmpty
            $script:config | Should -Not -BeNullOrEmpty
        }

        It 'every published port binds 127.0.0.1' {
            $ports = @(Get-PublishedPorts $script:config)
            $ports.Count | Should -BeGreaterThan 0
            foreach ($port in $ports) {
                $port.host_ip | Should -Be '127.0.0.1'
            }
        }

        It 'volume names fall back to the project name without VOLUME_PREFIX' {
            # A set VOLUME_PREFIX is checked once per provider and mode in 'Compose VOLUME_PREFIX' below.
            $script:config.volumes.($providerVolume[$Provider]).name | Should -Be "fixture_$($providerVolume[$Provider])"
            foreach ($volume in $script:config.volumes.PSObject.Properties.Value) {
                $volume.name | Should -BeLike 'fixture_*'
            }
        }

        It 'long-running services restart unless-stopped, the setup container never' {
            foreach ($service in $script:config.services.PSObject.Properties) {
                if ($service.Name -eq 'es-setup') {
                    $service.Value.PSObject.Properties.Name | Should -Not -Contain 'restart'
                }
                else {
                    $service.Value.restart | Should -Be 'unless-stopped' -Because "service $($service.Name)"
                }
            }
        }

        It 'es-limited sets single-node and drops memlock' {
            if (-not $Elasticsearch) {
                $script:config.services.PSObject.Properties.Name | Should -Not -Contain 'es'
                return
            }
            $es = $script:config.services.es
            if ($EsLimited) {
                $es.environment.'discovery.type' | Should -Be 'single-node'
                $es.environment.'bootstrap.memory_lock' | Should -Be 'false'
                # Strictly null, not '': an empty value crashes Elasticsearch ("null-valued setting")
                $es.environment.PSObject.Properties.Name | Should -Contain 'cluster.initial_master_nodes'
                ($null -eq $es.environment.'cluster.initial_master_nodes') | Should -BeTrue
                $es.PSObject.Properties.Name | Should -Not -Contain 'ulimits'
            }
            else {
                $es.environment.PSObject.Properties.Name | Should -Not -Contain 'discovery.type'
                $es.environment.'cluster.initial_master_nodes' | Should -Be 'es'
                $es.environment.'bootstrap.memory_lock' | Should -Be 'true'
                $es.ulimits.memlock.soft | Should -Be -1
            }
        }

        It 'vc-db has a healthcheck' {
            $script:config.services.'vc-db'.healthcheck.test | Should -Not -BeNullOrEmpty
        }

        It 'wires only the services that are listed' {
            $names = @($script:config.services.PSObject.Properties.Name)
            ($names -contains 'es') | Should -Be $Elasticsearch
            ($names -contains 'kibana') | Should -Be $Kibana
            ($names -contains 'redis') | Should -Be $Redis
            ($names -contains 'vc-db') | Should -BeTrue
            ($names -contains 'vc-platform-web') | Should -Be $Platform
            ($names -contains 'vc-frontend') | Should -Be $Frontend
        }

        It 'platform depends_on is exactly the implied set, all service_healthy' {
            if (-not $Platform) {
                return
            }
            $implied = @('vc-db') + @(if ($Elasticsearch) { 'es' }) + @(if ($Redis) { 'redis' })
            $dependsOn = $script:config.services.'vc-platform-web'.depends_on
            @($dependsOn.PSObject.Properties.Name | Sort-Object) | Should -Be @($implied | Sort-Object)
            foreach ($dependency in $dependsOn.PSObject.Properties) {
                $dependency.Value.condition | Should -Be 'service_healthy' -Because "dependency $($dependency.Name)"
            }
        }

        It 'image tags are vc-platform:<project>-latest and vc-frontend:<project>-latest' {
            if ($Platform) {
                $script:config.services.'vc-platform-web'.image | Should -Be "vc-platform:$($script:config.name)-latest"
            }
            if ($Frontend) {
                $script:config.services.'vc-frontend'.image | Should -Be "vc-frontend:$($script:config.name)-latest"
            }
        }

        It 'frontend without platform gets host.docker.internal upstream and the host-gateway extra_host' {
            if (-not $Frontend) {
                $script:config.services.PSObject.Properties.Name | Should -Not -Contain 'vc-frontend'
                return
            }
            $frontend = $script:config.services.'vc-frontend'
            if ($Platform) {
                $frontend.environment.PLATFORM_UPSTREAM | Should -Be 'vc-platform-web:8090'
                $frontend.depends_on.'vc-platform-web'.condition | Should -Be 'service_healthy'
                # nginx resolves vc-platform-web once, at start: a recreated platform restarts the storefront.
                $frontend.depends_on.'vc-platform-web'.restart | Should -BeTrue
                $frontend.PSObject.Properties.Name | Should -Not -Contain 'extra_hosts'
            }
            else {
                $frontend.environment.PLATFORM_UPSTREAM | Should -Be 'host.docker.internal:8090'
                # Compose 2.24.6 and newer render extra_hosts as 'host=ip'; the replace keeps the check tolerant of the 'host:ip' spelling.
                @($frontend.extra_hosts | ForEach-Object { $_ -replace '^host\.docker\.internal:', 'host.docker.internal=' }) | Should -Contain 'host.docker.internal=host-gateway'
                $frontend.PSObject.Properties.Name | Should -Not -Contain 'depends_on'
            }
            $mode = if ($Https) { 'https' } else { 'http' }
            $frontend.environment.PLATFORM_SCHEME | Should -Be $mode
            $frontend.environment.NGINX_ENVSUBST_TEMPLATE_DIR | Should -Be "/etc/nginx/templates-$mode"
            $frontend.environment.NGINX_ENVSUBST_FILTER | Should -Be '^PLATFORM_'
            # The container port is fixed: the mode never changes the port mapping.
            @($frontend.ports | ForEach-Object { $_.target }) | Should -Be @(8080)
            $certs = @($frontend.volumes | Where-Object { $_.source -eq 'certs' })
            if ($Https) {
                $certs.Count | Should -Be 1
                $certs[0].target | Should -Be '/certs'
                $certs[0].read_only | Should -BeTrue
            }
            else {
                $certs.Count | Should -Be 0
            }
        }

        It 'the platform serves HTTP in HTTP mode and TLS with the dev certificate in HTTPS mode' {
            if (-not $Platform) {
                return
            }
            $platformService = $script:config.services.'vc-platform-web'
            $environment = $platformService.environment
            $scheme = if ($Https) { 'https' } else { 'http' }
            $environment.ASPNETCORE_URLS | Should -Be "${scheme}://+:8090"
            $environment.'VirtoCommerce__AllowInsecureHttp' | Should -Be (-not $Https).ToString().ToLowerInvariant()
            $environment.'Assets__FileSystem__PublicUrl' | Should -Be "${scheme}://localhost:8090/assets/"
            $environment.'Content__FileSystem__PublicUrl' | Should -Be "${scheme}://localhost:8090/cms-content/"
            @($platformService.ports | ForEach-Object { $_.target }) | Should -Be @(8090)
            # The official vc-docker image has no curl: bash /dev/tcp checks HTTP, openssl s_client checks HTTPS.
            $platformService.healthcheck.test[-1] | Should -BeLike '*GET /health HTTP/1.1*'
            $platformService.healthcheck.test[-1] | Should -Not -BeLike '*curl*'
            $certs = @($platformService.volumes | Where-Object { $_.source -eq 'certs' })
            if ($Https) {
                $environment.'Kestrel__Certificates__Default__Path' | Should -Be '/certs/dev/localhost.pem'
                $environment.'Kestrel__Certificates__Default__KeyPath' | Should -Be '/certs/dev/localhost.key'
                $platformService.healthcheck.test[-1] | Should -BeLike '*openssl s_client*127.0.0.1:8090*'
                $certs.Count | Should -Be 1
                $certs[0].target | Should -Be '/certs'
                $certs[0].read_only | Should -BeTrue
            }
            else {
                $environment.PSObject.Properties.Name | Should -Not -Contain 'Kestrel__Certificates__Default__Path'
                $platformService.healthcheck.test[-1] | Should -BeLike '*/dev/tcp/127.0.0.1/8090*'
                $certs.Count | Should -Be 0
            }
        }

        It 'the platform trusts the Elasticsearch setup CA through SSL_CERT_DIR in HTTPS mode' {
            if (-not ($Platform -and $Https -and $Elasticsearch)) {
                return
            }
            $environment = $script:config.services.'vc-platform-web'.environment
            $environment.SSL_CERT_DIR | Should -Be '/etc/ssl/certs:/certs/ca'
            $environment.PSObject.Properties.Name | Should -Not -Contain 'SEARCH_PROVIDER'
        }

        It 'HTTPS mode adds the certs volume and, with Elasticsearch, the setup container' {
            $names = @($script:config.services.PSObject.Properties.Name)
            ($names -contains 'es-setup') | Should -Be ($Https -and $Elasticsearch)
            # Compose leaves a volume out of the merged config when no service mounts it.
            $hasCerts = $script:config.volumes.PSObject.Properties.Name -contains 'certs'
            if ($Https) {
                ($ComposeFiles -contains 'docker-compose/https.yml') | Should -BeTrue
                # Mounted by es and Kibana, and by the platform and the storefront (the dev certificate).
                $hasCerts | Should -Be ($Elasticsearch -or $Platform -or $Frontend)
                if ($hasCerts) {
                    $script:config.volumes.certs.name | Should -Be 'fixture_certs'
                }
            }
            else {
                $hasCerts | Should -BeFalse
                @($ComposeFiles | Where-Object { $_ -like '*.https.yml' }) | Should -BeNullOrEmpty
            }
        }

        It 'Elasticsearch and Kibana speak HTTP in HTTP mode and HTTPS in HTTPS mode' {
            $scheme = if ($Https) { 'https' } else { 'http' }
            $otherScheme = if ($Https) { 'http' } else { 'https' }
            $secured = @('es', 'kibana') | Where-Object { $script:config.services.PSObject.Properties.Name -contains $_ }
            foreach ($name in $secured) {
                $service = $script:config.services.$name
                $service.healthcheck.test[-1] | Should -BeLike "*${scheme}://localhost:*" -Because "$name healthcheck"
                $service.healthcheck.test[-1] | Should -Not -BeLike "*${otherScheme}://*" -Because "$name healthcheck"
                foreach ($entry in $service.environment.PSObject.Properties) {
                    "$($entry.Value)" | Should -Not -BeLike "${otherScheme}://*" -Because "$name $($entry.Name)"
                }
            }
            if ($Kibana) {
                $script:config.services.kibana.environment.ELASTICSEARCH_HOSTS | Should -Be "${scheme}://es:9200"
                if ($Https) {
                    $script:config.services.kibana.environment.SERVER_SSL_ENABLED | Should -Be 'true'
                    $script:config.services.kibana.environment.ELASTICSEARCH_SSL_CERTIFICATEAUTHORITIES | Should -Be 'config/certs/ca/ca.crt'
                    $script:config.services.kibana.volumes.source | Should -Contain 'certs'
                }
                else {
                    $script:config.services.kibana.environment.PSObject.Properties.Name | Should -Not -Contain 'SERVER_SSL_ENABLED'
                }
            }
            if ($Platform -and $Elasticsearch) {
                $server = $script:config.services.'vc-platform-web'.environment.'Search__ElasticSearch8__Server'
                $server | Should -Be "${scheme}://es:9200"
                $certs = @($script:config.services.'vc-platform-web'.volumes | Where-Object { $_.source -eq 'certs' })
                if ($Https) {
                    $certs.Count | Should -Be 1
                    $certs[0].target | Should -Be '/certs'
                    $certs[0].read_only | Should -BeTrue
                }
                else {
                    $certs.Count | Should -Be 0
                }
            }
        }

        It 'es waits for a healthy es-setup and runs with security and TLS on' {
            if (-not ($Https -and $Elasticsearch)) {
                return
            }
            $es = $script:config.services.es
            $es.depends_on.'es-setup'.condition | Should -Be 'service_healthy'
            $es.environment.'xpack.security.enabled' | Should -Be 'true'
            $es.environment.'xpack.security.http.ssl.enabled' | Should -Be 'true'
            $es.environment.'xpack.security.transport.ssl.enabled' | Should -Be 'true'
            # E11: Elasticsearch sends the CA with its certificate, so the platform's CA fingerprint finds it in the chain.
            $es.environment.'xpack.security.http.ssl.certificate' | Should -Be 'certs/es/es-chain.crt'
            $es.volumes.target | Should -Contain '/usr/share/elasticsearch/config/certs'
            $setup = $script:config.services.'es-setup'
            $setup.healthcheck.test[-1] | Should -BeLike '*ca/ca.fingerprint*'
            # Quoted, as es-setup's own call is: an inner space would split it into two curl arguments.
            $es.healthcheck.test[-1] | Should -BeLike '*-u "elastic:$$ELASTIC_PASSWORD"*'
            $setup.healthcheck.test[-1] | Should -BeLike '*es/es-chain.crt*'
            # The chain is leaf first, then CA, and is written on every run: after the once-per-volume guards (so volumes
            # made before the chain file get it) and before ca.fingerprint, which the health check waits for.
            $setupScript = [string]$setup.command[-1]
            $chainIndex = $setupScript.IndexOf('cat es/es.crt ca/ca.crt > es/es-chain.crt', [System.StringComparison]::Ordinal)
            $chainIndex | Should -BeGreaterOrEqual 0 -Because 'es-setup writes es/es-chain.crt as the es certificate followed by the CA'
            $lastGuardEnd = ([regex]::Matches($setupScript, '(?m)^\s*fi\s*$') | Select-Object -Last 1).Index
            $chainIndex | Should -BeGreaterThan $lastGuardEnd -Because 'the chain is written outside the certs.zip guard'
            $fingerprintIndex = $setupScript.IndexOf('> config/certs/ca/ca.fingerprint', [System.StringComparison]::Ordinal)
            $chainIndex | Should -BeLessThan $fingerprintIndex -Because 'ca.fingerprint is written last'
            $setup.environment.PSObject.Properties.Name | Should -Contain 'KIBANA_PASSWORD'
            # Every certificate names its stack: two stacks' CAs trusted on one host never share a subject (the certutil
            # default is one fixed DN for every CA).
            $project = $script:config.name
            $setupScript | Should -BeLike "*elasticsearch-certutil ca *--ca-dn `"CN=Elasticsearch CA,UID=$project,OU=start-local,O=VirtoCommerce`"*"
            $setupScript | Should -BeLike "*name: `"CN=es,UID=$project,OU=start-local,O=VirtoCommerce`"*filename: es*"
            $setupScript | Should -BeLike "*name: `"CN=kibana,UID=$project,OU=start-local,O=VirtoCommerce`"*filename: kibana*"
        }

        It 'platform-modules is never listed without source modules' {
            $ComposeFiles | Should -Not -Contain 'docker-compose/platform-modules.yml'
        }
    }

    It 'project name matches Get-ComposeProjectName (<FolderName>)' -ForEach @(
        @{ FolderName = 'VirtoLocal' }
        @{ FolderName = 'My Stack.v2' }
    ) {
        $folder = New-ComposeFixtureFolder -ComposeFiles 'docker-compose.yml', 'docker-compose/postgres.yml' -FolderName $FolderName
        try {
            (Invoke-ComposeConfigJson $folder).name | Should -Be (Get-ComposeProjectName $folder)
        }
        finally {
            Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Compose VOLUME_PREFIX' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    # The full stack mounts every volume the matrix above can name, so one run per provider and mode covers them all.
    # An exported VOLUME_PREFIX takes precedence over .env in Compose's interpolation, so the fixture needs no second copy.
    It 'names every volume with VOLUME_PREFIX (<Provider>, https: <Https>)' -ForEach @(
        foreach ($https in $false, $true) {
            foreach ($provider in 'postgres', 'mysql', 'sqlserver') {
                @{ Provider = $provider; Https = $https }
            }
        }
    ) {
        $requested = @('docker-compose.yml') + @(if ($Https) { 'docker-compose/https.yml' }) + @(
            "docker-compose/$Provider.yml", 'docker-compose/platform.yml', 'docker-compose/frontend.yml',
            'docker-compose/elasticsearch.yml', 'docker-compose/kibana.yml', 'docker-compose/redis.yml')
        $files = [string[]](Update-ComposeFileList -ComposeFiles $requested -HasSourceModules $false)
        $folder = New-ComposeFixtureFolder -ComposeFiles $files
        $previousPrefix = $env:VOLUME_PREFIX
        $env:VOLUME_PREFIX = 'virto'
        try {
            $config = Invoke-ComposeConfigJson $folder
        }
        finally {
            $env:VOLUME_PREFIX = $previousPrefix
            Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        }

        $config.volumes.($providerVolume[$Provider]).name | Should -Be "virto_$($providerVolume[$Provider])"
        $config.volumes.esdata01.name | Should -Be 'virto_esdata01'
        if ($Https) {
            $config.volumes.certs.name | Should -Be 'virto_certs'
        }
        foreach ($volume in $config.volumes.PSObject.Properties) {
            $volume.Value.name | Should -Be "virto_$($volume.Name)"
        }
    }
}

Describe 'Compose V12: all links of a platform' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    It 'merges depends_on of vc-db, es and redis, each service_healthy' {
        $files = [string[]](Update-ComposeFileList -HasSourceModules $false -ComposeFiles @(
                'docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml',
                'docker-compose/elasticsearch.yml', 'docker-compose/redis.yml', 'docker-compose/frontend.yml'))
        $folder = New-ComposeFixtureFolder -ComposeFiles $files
        try {
            $dependsOn = (Invoke-ComposeConfigJson $folder).services.'vc-platform-web'.depends_on
            foreach ($name in 'vc-db', 'es', 'redis') {
                $dependsOn.$name.condition | Should -Be 'service_healthy' -Because "dependency $name"
            }
        }
        finally {
            Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Compose: uploaded assets' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    It 'the Docker platform keeps wwwroot/assets on the assets-data volume' {
        $files = [string[]](Update-ComposeFileList -HasSourceModules $false -ComposeFiles @(
                'docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml'))
        $folder = New-ComposeFixtureFolder -ComposeFiles $files
        try {
            $config = Invoke-ComposeConfigJson $folder
        }
        finally {
            Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        }

        $assets = $config.services.'vc-platform-web'.volumes | Where-Object { $_.target -eq '/opt/virtocommerce/platform/wwwroot/assets' }
        $assets.type | Should -Be 'volume'
        $assets.source | Should -Be 'assets-data'
        $config.volumes.'assets-data'.name | Should -Be 'fixture_assets-data'
    }
}

Describe 'Compose V13: generated platform-modules' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    BeforeAll {
        function script:Get-PlatformModulesVolumes {
            # The platform's volumes of a stack with the generated file for $Paths, by mount target.
            param([string[]]$Paths)

            $mountPlan = Get-ModuleMountPlan -Classification (Get-ModuleSourceKind -Paths $Paths)
            $files = [string[]](Update-ComposeFileList -HasSourceModules ($mountPlan.Count -gt 0) -ComposeFiles @(
                    'docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml'))
            $folder = New-ComposeFixtureFolder -ComposeFiles $files
            try {
                Write-ModulesComposeFile -SolutionFolder $folder -MountPlan $mountPlan
                $volumes = (Invoke-ComposeConfigJson $folder).services.'vc-platform-web'.volumes
                $byTarget = @{}
                foreach ($volume in $volumes) {
                    $byTarget[$volume.target] = $volume
                }
                $byTarget
            }
            finally {
                Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        function script:New-SourceFolder {
            param([string]$Name, [string]$ModuleId)
            $path = Join-Path $TestDrive $Name
            $null = New-Item -ItemType Directory -Path $path -Force
            if ($ModuleId) {
                Set-Content -LiteralPath (Join-Path $path 'module.manifest') -Value "<module><id>$ModuleId</id></module>"
            }
            $path
        }
    }

    It 'a modules folder is the bind source at the modules path' {
        $modules = New-SourceFolder 'modules'

        $volumes = Get-PlatformModulesVolumes -Paths @($modules)

        $volume = $volumes['/opt/virtocommerce/platform/modules']
        $volume.type | Should -Be 'bind'
        ($volume.source -replace '\\', '/') | Should -Be ($modules -replace '\\', '/')
        $volumes['/opt/virtocommerce/platform/wwwroot/cms-content'].type | Should -Be 'volume'
    }

    It '*.Web folders are bind mounts over the image''s modules, one per module id' {
        $catalog = New-SourceFolder 'Catalog.Web' 'VirtoCommerce.Catalog'
        $cart = New-SourceFolder 'Cart.Web' 'VirtoCommerce.Cart'

        $volumes = Get-PlatformModulesVolumes -Paths @($catalog, $cart)

        $volumes.Keys | Should -Not -Contain '/opt/virtocommerce/platform/modules'
        $volumes['/opt/virtocommerce/platform/modules/VirtoCommerce.Catalog'].type | Should -Be 'bind'
        $volumes['/opt/virtocommerce/platform/modules/VirtoCommerce.Cart'].type | Should -Be 'bind'
        ($volumes['/opt/virtocommerce/platform/modules/VirtoCommerce.Cart'].source -replace '\\', '/') | Should -Be ($cart -replace '\\', '/')
    }

    # The image's modules are the build's: a volume over them would keep the first build's modules through every rebuild
        # (Docker fills a named volume from the image only while it is empty). Modules installed from the UI do not survive
        # a new container, as in VirtoCloud.
    It 'no source modules mounts nothing over the image''s modules' {
        $volumes = Get-PlatformModulesVolumes -Paths @()

        $volumes.Keys | Should -Not -Contain '/opt/virtocommerce/platform/modules'
        $volumes.Keys | Should -Not -Contain '/opt/virtocommerce/platform/modules/VirtoCommerce.Catalog'
    }

    It 'a path with a dollar sign reaches Compose literally' {
        $folder = New-SourceFolder 'cost$HOME' 'VirtoCommerce.Catalog'

        $volumes = Get-PlatformModulesVolumes -Paths @($folder)

        $volumes['/opt/virtocommerce/platform/modules/VirtoCommerce.Catalog'].source | Should -Match '\$HOME$'
    }
}

Describe 'Compose files' -Tag 'Compose' {
    It 'platform-modules is listed only with source modules and a platform' {
        $base = 'docker-compose.yml', 'docker-compose/postgres.yml'
        $withPlatform = [string[]]($base + 'docker-compose/platform.yml')
        $modules = 'docker-compose/platform-modules.yml'
        [string[]](Update-ComposeFileList -ComposeFiles $withPlatform -HasSourceModules $true) | Should -Contain $modules
        [string[]](Update-ComposeFileList -ComposeFiles $base -HasSourceModules $true) | Should -Not -Contain $modules
        [string[]](Update-ComposeFileList -ComposeFiles $withPlatform -HasSourceModules $false) | Should -Not -Contain $modules
    }

    It 'every compose file in the repo is in the catalog, and only docker-compose.yml is in the root' {
        $repositoryRoot = Get-TestRepositoryRoot
        $catalogNames = @($script:ComposeFileCatalog | ForEach-Object { $_.Name })
        $rootFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Filter 'docker-compose*.yml' -File | ForEach-Object { $_.Name })
        $rootFiles | Should -Be @('docker-compose.yml')
        $folderFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot $script:ComposeFolderName) -Filter '*.yml' -File |
                ForEach-Object { Get-ComposeFileName $_.Name })
        $folderFiles.Count | Should -BeGreaterThan 20
        @($rootFiles + $folderFiles | Where-Object { $catalogNames -cnotcontains $_ }) | Should -BeNullOrEmpty
    }
}

Describe 'Compose platform port' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    # S7: the platform listens on PLATFORM_PORT inside the container as well, so one port names it for every caller.
    # The storefront's container port stays 8080.
    It 'the platform listens, publishes and checks its health on PLATFORM_PORT (<Scheme>)' -ForEach @(
        @{ Scheme = 'http'; Https = $false }
        @{ Scheme = 'https'; Https = $true }
    ) {
        $files = @('docker-compose.yml') + @(if ($Https) { 'docker-compose/https.yml' }) + @(
            'docker-compose/postgres.yml', 'docker-compose/platform.yml', 'docker-compose/frontend.yml'
        )
        $normalized = [string[]](Update-ComposeFileList -ComposeFiles $files -HasSourceModules $false)
        $folder = New-ComposeFixtureFolder -ComposeFiles $normalized -EnvOverrides @{ PLATFORM_PORT = '8123' }
        try {
            $config = Invoke-ComposeConfigJson $folder
        }
        finally {
            Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        }
        $platform = $config.services.'vc-platform-web'

        $platform.environment.ASPNETCORE_URLS | Should -Be "${Scheme}://+:8123"
        @($platform.ports | ForEach-Object { $_.target }) | Should -Be @(8123)
        @($platform.ports | ForEach-Object { $_.published }) | Should -Be @('8123')
        if ($Https) {
            $platform.healthcheck.test[-1] | Should -BeLike '*openssl s_client*127.0.0.1:8123*'
        }
        else {
            $platform.healthcheck.test[-1] | Should -BeLike '*/dev/tcp/127.0.0.1/8123*'
        }
        $config.services.'vc-frontend'.environment.PLATFORM_UPSTREAM | Should -Be 'vc-platform-web:8123'
        @($config.services.'vc-frontend'.ports | ForEach-Object { $_.target }) | Should -Be @(8080)
    }

    It 'a standalone platform defaults the database, scope, channels and Redis database, and follows the .env values' {
        $files = [string[]](Update-ComposeFileList -HasSourceModules $false -ComposeFiles @(
                'docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/platform.yml'
                'docker-compose/elasticsearch.yml', 'docker-compose/redis.yml'))
        $defaultFolder = New-ComposeFixtureFolder -ComposeFiles $files
        $customFolder = New-ComposeFixtureFolder -ComposeFiles $files -EnvOverrides @{
            DB_NAME = 'Tenant_One'; SEARCH_SCOPE = 'tenant'; REDIS_CHANNEL = 'Channel-tenant'; REDIS_DATABASE = '4'
        }
        try {
            $default = (Invoke-ComposeConfigJson $defaultFolder).services.'vc-platform-web'.environment
            $custom = (Invoke-ComposeConfigJson $customFolder).services.'vc-platform-web'.environment
        }
        finally {
            foreach ($folder in $defaultFolder, $customFolder) {
                Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $default.ConnectionStrings__VirtoCommerce | Should -BeLike '*Database=VirtoCommerce3'
        $default.Search__Scope | Should -Be 'default'
        $default.ConnectionStrings__RedisConnectionString | Should -BeLike 'redis:6379,password=*,defaultDatabase=0'
        $default.Caching__Redis__ChannelName | Should -Be 'VirtoCommerceChannel'
        $default.PushNotifications__RedisBackplane__ChannelName | Should -Be 'VirtoCommerceChannel'

        $custom.ConnectionStrings__VirtoCommerce | Should -BeLike '*Database=Tenant_One'
        $custom.Search__Scope | Should -Be 'tenant'
        $custom.ConnectionStrings__RedisConnectionString | Should -BeLike 'redis:6379,password=*,defaultDatabase=4'
        $custom.Caching__Redis__ChannelName | Should -Be 'Channel-tenant'
        $custom.PushNotifications__RedisBackplane__ChannelName | Should -Be 'Channel-tenant'
    }

    It 'the database name reaches the MySQL and SQL Server connection strings' -ForEach @(
        @{ Provider = 'mysql' }
        @{ Provider = 'sqlserver' }
    ) {
        $files = [string[]](Update-ComposeFileList -HasSourceModules $false -ComposeFiles @('docker-compose.yml', "docker-compose/$Provider.yml", 'docker-compose/platform.yml'))
        $folder = New-ComposeFixtureFolder -ComposeFiles $files -EnvOverrides @{ DB_NAME = 'Tenant_One' }
        try {
            $connection = (Invoke-ComposeConfigJson $folder).services.'vc-platform-web'.environment.ConnectionStrings__VirtoCommerce
        }
        finally {
            Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        }

        $connection | Should -BeLike '*Database=Tenant_One;*'
    }
}
