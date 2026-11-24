BeforeDiscovery {
    $script:hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)
}

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    $script:roots = [System.Collections.Generic.List[string]]::new()

    function script:Get-PublishedPorts {
        param($Config)
        foreach ($service in $Config.services.PSObject.Properties.Value) {
            foreach ($port in $service.ports) {
                $port
            }
        }
    }

    function script:New-Fixture {
        # New-SharedStackFixture, its scratch root remembered for cleanup.
        param([string[]]$ServicesFiles, [string[]]$PlatformFiles, [hashtable]$PlatformEnv = @{}, [hashtable]$ServicesEnv = @{})

        $fixture = New-SharedStackFixture -ServicesFiles $ServicesFiles -PlatformFiles $PlatformFiles -PlatformEnv $PlatformEnv -ServicesEnv $ServicesEnv
        $script:roots.Add($fixture.Root)
        $fixture
    }

    function script:Get-ComposeVersionUnderTest {
        # The Compose the tests run: $env:SL_COMPOSE_BINARY when set, else the docker compose plugin.
        $output = if ($env:SL_COMPOSE_BINARY) { & $env:SL_COMPOSE_BINARY version --short 2>$null } else { & docker compose version --short 2>$null }
        (@($output) -join '').Trim()
    }

    # The services stack of the tests: every server, in HTTP or HTTPS mode.
    $script:servicesFiles = @{}
    $script:servicesFiles.Http = @(
        'docker-compose.yml'
        'docker-compose/postgres.yml', 'docker-compose/elasticsearch.yml', 'docker-compose/kibana.yml', 'docker-compose/kibana-elasticsearch.yml', 'docker-compose/redis.yml'
        'docker-compose/services-network.yml', 'docker-compose/services-database.yml', 'docker-compose/services-elasticsearch.yml', 'docker-compose/services-redis.yml'
    )
    $script:servicesFiles.Https = @(
        'docker-compose.yml', 'docker-compose/https.yml'
        'docker-compose/postgres.yml', 'docker-compose/elasticsearch.yml', 'docker-compose/elasticsearch.https.yml'
        'docker-compose/kibana.yml', 'docker-compose/kibana.https.yml', 'docker-compose/kibana-elasticsearch.yml', 'docker-compose/kibana-elasticsearch.https.yml'
        'docker-compose/redis.yml'
        'docker-compose/services-network.yml', 'docker-compose/services-database.yml', 'docker-compose/services-elasticsearch.yml', 'docker-compose/services-redis.yml'
    )

    # A platform stack: the platform, the storefront and every shared link, in HTTP or HTTPS mode.
    $script:platformFiles = @{}
    $script:platformFiles.Http = @(
        'docker-compose.yml', 'docker-compose/shared-network.yml'
        'docker-compose/shared-postgres.yml', 'docker-compose/shared-elasticsearch.yml', 'docker-compose/shared-redis.yml'
        'docker-compose/platform.yml', 'docker-compose/frontend.yml', 'docker-compose/platform-frontend.yml'
        'docker-compose/platform-shared.yml', 'docker-compose/platform-shared-postgres.yml'
        'docker-compose/platform-shared-elasticsearch.yml', 'docker-compose/platform-shared-redis.yml'
    )
    $script:platformFiles.Https = @(
        'docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/shared-certs.yml', 'docker-compose/shared-network.yml'
        'docker-compose/shared-postgres.yml', 'docker-compose/shared-elasticsearch.yml', 'docker-compose/shared-redis.yml'
        'docker-compose/platform.yml', 'docker-compose/platform.https.yml'
        'docker-compose/frontend.yml', 'docker-compose/frontend.https.yml', 'docker-compose/platform-frontend.yml'
        'docker-compose/platform-shared.yml', 'docker-compose/platform-shared.https.yml', 'docker-compose/platform-shared-postgres.yml'
        'docker-compose/platform-shared-elasticsearch.yml', 'docker-compose/platform-shared-elasticsearch.https.yml', 'docker-compose/platform-shared-redis.yml'
    )
}

AfterAll {
    foreach ($root in $script:roots) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Shared stacks' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    Context 'the services stack' {
        It 'vc-db, es and redis join the shared network; kibana and es-setup do not (<Mode>)' -ForEach @(
            @{ Mode = 'Http' }
            @{ Mode = 'Https' }
        ) {
            $folder = New-ComposeFixtureFolder -ComposeFiles $script:servicesFiles[$Mode] -FolderName 'services'
            $script:roots.Add((Split-Path $folder -Parent))
            $config = Invoke-ComposeConfigJson $folder

            $config.networks.shared.name | Should -Be 'services-shared'
            $config.networks.shared.PSObject.Properties.Name | Should -Not -Contain 'external'
            foreach ($name in 'vc-db', 'es', 'redis') {
                @($config.services.$name.networks.PSObject.Properties.Name | Sort-Object) | Should -Be @('shared', 'virto') -Because $name
            }
            @($config.services.kibana.networks.PSObject.Properties.Name) | Should -Be @('virto')
            if ($Mode -eq 'Https') {
                @($config.services.'es-setup'.networks.PSObject.Properties.Name) | Should -Be @('virto')
            }
        }

        It 'names its network before SERVICES_NETWORK_NAME exists' {
            # P17: the key is absent from .env until services start has passed preflight, so the file falls back to the project name.
            $folder = New-ComposeFixtureFolder -ComposeFiles @('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/services-network.yml', 'docker-compose/services-database.yml') -FolderName 'svc'
            $script:roots.Add((Split-Path $folder -Parent))
            (Get-Content -Raw -LiteralPath (Join-Path $folder '.env')) | Should -Not -Match 'SERVICES_NETWORK_NAME'

            (Invoke-ComposeConfigJson $folder).networks.shared.name | Should -Be 'svc-shared'
        }
    }

    Context 'a platform stack' {
        It 'reads the services .env in place' {
            $fixture = New-Fixture -ServicesFiles $script:servicesFiles.Http -PlatformFiles $script:platformFiles.Http -ServicesEnv @{ DB_PASSWORD = 'OnlyInServicesEnv1' }
            (Get-Content -Raw -LiteralPath (Join-Path $fixture.PlatformFolder '.env')) | Should -Not -Match 'DB_PASSWORD'

            $config = Invoke-ComposeConfigJson $fixture.PlatformFolder

            $config.name | Should -Be 'platform'
            $config.services.'vc-platform-web'.environment.ConnectionStrings__VirtoCommerce | Should -BeLike '*Password=OnlyInServicesEnv1;*'
            $config.services.'vc-platform-web'.environment.ConnectionStrings__VirtoCommerce | Should -BeLike '*Database=VirtoCommerce_platform'
        }

        It 'is shadowed by an empty platform key' {
            # P2: a key present but empty in the platform .env wins over the services value, so Task 2 removes the services-owned keys.
            $fixture = New-Fixture -ServicesFiles $script:servicesFiles.Http -PlatformFiles $script:platformFiles.Http -PlatformEnv @{ DB_PASSWORD = '' }

            { Invoke-ComposeConfigJson $fixture.PlatformFolder } | Should -Throw '*DB_PASSWORD is empty in .env*'
        }

        It 'joins the external network with its alias' {
            $fixture = New-Fixture -ServicesFiles $script:servicesFiles.Http -PlatformFiles $script:platformFiles.Http -PlatformEnv @{ PLATFORM_HOSTNAME = 'mgmt.dev.internal' }

            $config = Invoke-ComposeConfigJson $fixture.PlatformFolder

            $config.networks.shared.external | Should -BeTrue
            $config.networks.shared.name | Should -Be 'services-shared'
            $config.services.'vc-platform-web'.networks.shared.aliases | Should -Contain 'mgmt.dev.internal'
            # The storefront stays off the shared network (S15).
            @($config.services.'vc-frontend'.networks.PSObject.Properties.Name) | Should -Be @('virto')
        }

        It 'has no depends_on on the services' {
            $fixture = New-Fixture -ServicesFiles $script:servicesFiles.Http -PlatformFiles $script:platformFiles.Http

            $config = Invoke-ComposeConfigJson $fixture.PlatformFolder

            $config.services.'vc-platform-web'.PSObject.Properties.Name | Should -Not -Contain 'depends_on'
            $config.services.PSObject.Properties.Name | Should -Not -Contain 'vc-db'
        }

        It 'wires the platform to the <Provider> server with its own database and no depends_on' -ForEach @(
            @{ Provider = 'postgres'; DatabaseProvider = 'PostgreSql' }
            @{ Provider = 'mysql'; DatabaseProvider = 'MySql' }
            @{ Provider = 'sqlserver'; DatabaseProvider = 'SqlServer' }
        ) {
            $servicesFiles = @('docker-compose.yml', "docker-compose/$Provider.yml", 'docker-compose/services-network.yml', 'docker-compose/services-database.yml')
            $platformFiles = @('docker-compose.yml', 'docker-compose/shared-network.yml', "docker-compose/shared-$Provider.yml", 'docker-compose/platform.yml', 'docker-compose/platform-shared.yml', "docker-compose/platform-shared-$Provider.yml")
            $fixture = New-Fixture -ServicesFiles $servicesFiles -PlatformFiles $platformFiles -ServicesEnv @{ DB_PASSWORD = 'OnlyInServicesEnv1' }

            $platform = (Invoke-ComposeConfigJson $fixture.PlatformFolder).services.'vc-platform-web'

            $platform.environment.DatabaseProvider | Should -Be $DatabaseProvider
            $platform.environment.ConnectionStrings__VirtoCommerce | Should -BeLike '*Database=VirtoCommerce_platform*'
            $platform.environment.ConnectionStrings__VirtoCommerce | Should -BeLike '*Password=OnlyInServicesEnv1*'
            $platform.PSObject.Properties.Name | Should -Not -Contain 'depends_on'
        }

        It 'gets its isolation keys: database, scope, channels and Redis database' {
            $fixture = New-Fixture -ServicesFiles $script:servicesFiles.Http -PlatformFiles $script:platformFiles.Http -PlatformEnv @{ REDIS_DATABASE = '3'; SEARCH_SCOPE = 'tenant' }

            $environment = (Invoke-ComposeConfigJson $fixture.PlatformFolder).services.'vc-platform-web'.environment

            $environment.Search__Scope | Should -Be 'tenant'
            $environment.ConnectionStrings__RedisConnectionString | Should -BeLike 'redis:6379,password=*,defaultDatabase=3'
            $environment.Caching__Redis__ChannelName | Should -Be 'VirtoCommerceChannel-platform'
            $environment.PushNotifications__RedisBackplane__ChannelName | Should -Be 'VirtoCommerceChannel-platform'
            $environment.Search__ElasticSearch8__Server | Should -Be 'http://es:9200'
            $environment.DatabaseProvider | Should -Be 'PostgreSql'
        }

        It 'HTTPS: certs is the external services volume, mounted by the platform and the storefront' {
            $fixture = New-Fixture -ServicesFiles $script:servicesFiles.Https -PlatformFiles $script:platformFiles.Https

            $config = Invoke-ComposeConfigJson $fixture.PlatformFolder

            $config.volumes.certs.external | Should -BeTrue
            $config.volumes.certs.name | Should -Be 'services_certs'
            foreach ($name in 'vc-platform-web', 'vc-frontend') {
                $mount = @($config.services.$name.volumes | Where-Object { $_.source -eq 'certs' })
                $mount.Count | Should -Be 1 -Because $name
                $mount[0].read_only | Should -BeTrue -Because $name
            }
            $config.services.'vc-platform-web'.environment.SSL_CERT_DIR | Should -Be '/etc/ssl/certs:/certs/ca'
            $config.services.'vc-platform-web'.environment.Search__ElasticSearch8__Server | Should -Be 'https://es:9200'
        }

        It 'every published port follows its own folder''s non-default BIND_ADDRESS in both roles' {
            # S16, and P2 for a key the platform keeps: each role reads its own value, not the other's.
            $fixture = New-Fixture -ServicesFiles $script:servicesFiles.Https -PlatformFiles $script:platformFiles.Https -ServicesEnv @{ BIND_ADDRESS = '127.0.0.2' } -PlatformEnv @{ BIND_ADDRESS = '127.0.0.3' }

            $expected = @(
                @{ Folder = $fixture.ServicesFolder; HostIp = '127.0.0.2' }
                @{ Folder = $fixture.PlatformFolder; HostIp = '127.0.0.3' }
            )
            foreach ($case in $expected) {
                $ports = @(Get-PublishedPorts (Invoke-ComposeConfigJson $case.Folder))
                $ports.Count | Should -BeGreaterThan 0 -Because $case.Folder
                foreach ($port in $ports) {
                    $port.host_ip | Should -Be $case.HostIp -Because $case.Folder
                }
            }
        }

        It 'PublicUrl uses PLATFORM_HOSTNAME and PLATFORM_PORT (<Scheme>)' -ForEach @(
            @{ Scheme = 'https'; Mode = 'Https' }
            @{ Scheme = 'http'; Mode = 'Http' }
        ) {
            $fixture = New-Fixture -ServicesFiles $script:servicesFiles[$Mode] -PlatformFiles $script:platformFiles[$Mode] -PlatformEnv @{ PLATFORM_HOSTNAME = 'mgmt.dev.internal'; PLATFORM_PORT = '8091' }

            $environment = (Invoke-ComposeConfigJson $fixture.PlatformFolder).services.'vc-platform-web'.environment

            $environment.Assets__FileSystem__PublicUrl | Should -Be "${Scheme}://mgmt.dev.internal:8091/assets/"
            $environment.Content__FileSystem__PublicUrl | Should -Be "${Scheme}://mgmt.dev.internal:8091/cms-content/"
        }

        It 'the alias file follows the Compose version (P19)' {
            $files = $script:platformFiles.Http + 'docker-compose/platform-shared-alias.yml'
            $fixture = New-Fixture -ServicesFiles $script:servicesFiles.Http -PlatformFiles $files -PlatformEnv @{ PLATFORM_HOSTNAME = 'mgmt.dev.internal' }
            $version = Get-ComposeVersionUnderTest
            $version | Should -Not -BeNullOrEmpty

            if (Test-ComposeVersion $version '5.7.0') {
                $network = (Invoke-ComposeConfigJson $fixture.PlatformFolder).services.'vc-platform-web'.networks.shared
                $network.PSObject.Properties.Name | Should -Contain 'use_service_name_alias'
                $network.use_service_name_alias | Should -BeExactly $false
                $network.aliases | Should -Contain 'mgmt.dev.internal'
            }
            else {
                # Every release before 5.7.0 rejects the key, which is why the file is listed only from 5.7.0 on.
                { Invoke-ComposeConfigJson $fixture.PlatformFolder } | Should -Throw '*use_service_name_alias*'
            }
        }

        It 'only the platform joins the shared network, and no environment value names vc-platform-web (S15)' {
            $fixture = New-Fixture -ServicesFiles $script:servicesFiles.Https -PlatformFiles $script:platformFiles.Https

            $config = Invoke-ComposeConfigJson $fixture.PlatformFolder

            $joined = @($config.services.PSObject.Properties | Where-Object { $_.Value.networks.PSObject.Properties.Name -contains 'shared' } | ForEach-Object Name)
            $joined | Should -Be @('vc-platform-web')
            $config.services.PSObject.Properties.Name | Should -Contain 'vc-frontend'
            foreach ($value in $config.services.'vc-platform-web'.environment.PSObject.Properties.Value) {
                $value | Should -Not -BeLike '*vc-platform-web*'
            }
        }

        It 'with no service loads: a source platform and no storefront (P12)' {
            $fixture = New-Fixture -ServicesFiles $script:servicesFiles.Http -PlatformFiles @('docker-compose.yml', 'docker-compose/shared-network.yml', 'docker-compose/shared-postgres.yml')

            $config = Invoke-ComposeConfigJson $fixture.PlatformFolder

            @($config.services.PSObject.Properties).Count | Should -Be 0
        }
    }
}
