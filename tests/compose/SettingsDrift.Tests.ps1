# Keeps the compose YAML and Get-PlatformSettings equal (SPEC §5.3): both define the Docker platform's settings from one .env.
BeforeDiscovery {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)

    # 3 providers x Elasticsearch on/off x Redis on/off, in HTTP and in HTTPS mode, with a platform.
    $script:cases = foreach ($https in $false, $true) {
    foreach ($provider in 'postgres', 'mysql', 'sqlserver') {
        foreach ($elasticsearch in $false, $true) {
            foreach ($redis in $false, $true) {
                $requested = [System.Collections.Generic.List[string]]::new()
                $requested.Add('docker-compose.yml')
                if ($https) { $requested.Add('docker-compose/https.yml') }
                $requested.Add("docker-compose/$provider.yml")
                $requested.Add('docker-compose/platform.yml')
                if ($elasticsearch) { $requested.Add('docker-compose/elasticsearch.yml') }
                if ($redis) { $requested.Add('docker-compose/redis.yml') }
                @{
                    Label        = (@($provider) + @(if ($elasticsearch) { 'elasticsearch' }) + @(if ($redis) { 'redis' }) + @(if ($https) { 'https' })) -join '+'
                    ComposeFiles = [string[]](Update-ComposeFileList -ComposeFiles $requested.ToArray() -HasSourceModules $false)
                }
            }
        }
    }
    }

    # The same 3 x 2 x 2 x 2 matrix for a platform stack, whose servers sit in a services stack (S5): the services files
    # carry the servers, the platform files the markers and the platform-shared-* links.
    $script:stackCases = foreach ($https in $false, $true) {
    foreach ($provider in 'postgres', 'mysql', 'sqlserver') {
        foreach ($elasticsearch in $false, $true) {
            foreach ($redis in $false, $true) {
                $servicesFiles = [System.Collections.Generic.List[string]]::new()
                $servicesFiles.Add('docker-compose.yml')
                if ($https) { $servicesFiles.Add('docker-compose/https.yml') }
                $servicesFiles.Add("docker-compose/$provider.yml")
                if ($elasticsearch) { $servicesFiles.Add('docker-compose/elasticsearch.yml'); if ($https) { $servicesFiles.Add('docker-compose/elasticsearch.https.yml') } }
                if ($redis) { $servicesFiles.Add('docker-compose/redis.yml') }
                $servicesFiles.Add('docker-compose/services-network.yml')
                $servicesFiles.Add('docker-compose/services-database.yml')
                if ($elasticsearch) { $servicesFiles.Add('docker-compose/services-elasticsearch.yml') }
                if ($redis) { $servicesFiles.Add('docker-compose/services-redis.yml') }

                $platformFiles = [System.Collections.Generic.List[string]]::new()
                $platformFiles.Add('docker-compose.yml')
                if ($https) { $platformFiles.Add('docker-compose/https.yml'); $platformFiles.Add('docker-compose/shared-certs.yml') }
                $platformFiles.Add('docker-compose/shared-network.yml')
                $platformFiles.Add("docker-compose/shared-$provider.yml")
                if ($elasticsearch) { $platformFiles.Add('docker-compose/shared-elasticsearch.yml') }
                if ($redis) { $platformFiles.Add('docker-compose/shared-redis.yml') }
                $platformFiles.Add('docker-compose/platform.yml')
                if ($https) { $platformFiles.Add('docker-compose/platform.https.yml') }
                $platformFiles.Add('docker-compose/platform-shared.yml')
                if ($https) { $platformFiles.Add('docker-compose/platform-shared.https.yml') }
                $platformFiles.Add("docker-compose/platform-shared-$provider.yml")
                if ($elasticsearch) { $platformFiles.Add('docker-compose/platform-shared-elasticsearch.yml'); if ($https) { $platformFiles.Add('docker-compose/platform-shared-elasticsearch.https.yml') } }
                if ($redis) { $platformFiles.Add('docker-compose/platform-shared-redis.yml') }
                @{
                    Label         = (@($provider) + @(if ($elasticsearch) { 'elasticsearch' }) + @(if ($redis) { 'redis' }) + @(if ($https) { 'https' })) -join '+'
                    ServicesFiles = $servicesFiles.ToArray()
                    PlatformFiles = $platformFiles.ToArray()
                }
            }
        }
    }
    }
}

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"
}

Describe 'Platform settings drift' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    Context '<Label>' -ForEach $script:cases {
        BeforeAll {
            $folder = New-ComposeFixtureFolder -ComposeFiles $ComposeFiles
            try {
                $config = Invoke-ComposeConfigJson $folder
                $envValues = Get-EnvTable (Read-EnvFile (Join-Path $folder '.env'))
            }
            finally {
                Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
            }

            # Environment variable names spell the configuration separator as '__'.
            $script:composeSettings = [ordered]@{}
            foreach ($variable in $config.services.'vc-platform-web'.environment.PSObject.Properties) {
                $script:composeSettings[$variable.Name.Replace('__', ':')] = [string]$variable.Value
            }
            $script:functionSettings = Get-PlatformSettings -EnvValues $envValues -ComposeFiles $ComposeFiles -Topology Container
            $script:containerOnlyKeys = Get-ContainerOnlyKeys
        }

        It 'every key of the settings function is in the compose environment with an equal value' {
            foreach ($key in $script:functionSettings.Keys) {
                $script:composeSettings.Contains($key) | Should -BeTrue -Because "compose lacks $key"
                $script:composeSettings[$key] | Should -BeExactly $script:functionSettings[$key] -Because "value of $key"
            }
        }

        It 'every compose key outside the container-only keys is in the settings function' {
            foreach ($key in $script:composeSettings.Keys) {
                if ($script:containerOnlyKeys -contains $key) {
                    continue
                }
                $script:functionSettings.Contains($key) | Should -BeTrue -Because "the settings function lacks $key"
            }
        }
    }
}

Describe 'Platform settings drift, platform stack' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    Context '<Label>' -ForEach $script:stackCases {
        BeforeAll {
            $fixture = New-SharedStackFixture -ServicesFiles $ServicesFiles -PlatformFiles $PlatformFiles -PlatformEnv @{
                PLATFORM_HOSTNAME = 'mgmt.dev.internal'; PLATFORM_PORT = '8091'; SEARCH_SCOPE = 'tenant'; REDIS_CHANNEL = 'Channel-tenant'; REDIS_DATABASE = '3'
            }
            try {
                $config = Invoke-ComposeConfigJson $fixture.PlatformFolder
                $document = Read-EnvFile (Join-Path $fixture.PlatformFolder '.env')
                $envValues = Get-StackEnvTable -Document $document -SolutionFolder $fixture.PlatformFolder
                $composeFiles = [string[]](Get-EnvComposeFiles -Document $document)
            }
            finally {
                Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
            }

            $script:composeSettings = [ordered]@{}
            foreach ($variable in $config.services.'vc-platform-web'.environment.PSObject.Properties) {
                $script:composeSettings[$variable.Name.Replace('__', ':')] = [string]$variable.Value
            }
            $script:functionSettings = Get-PlatformSettings -EnvValues $envValues -ComposeFiles $composeFiles -Topology Container
            $script:containerOnlyKeys = Get-ContainerOnlyKeys
        }

        It 'every key of the settings function is in the compose environment with an equal value' {
            foreach ($key in $script:functionSettings.Keys) {
                $script:composeSettings.Contains($key) | Should -BeTrue -Because "compose lacks $key"
                $script:composeSettings[$key] | Should -BeExactly $script:functionSettings[$key] -Because "value of $key"
            }
        }

        It 'every compose key outside the container-only keys is in the settings function' {
            foreach ($key in $script:composeSettings.Keys) {
                if ($script:containerOnlyKeys -contains $key) {
                    continue
                }
                $script:functionSettings.Contains($key) | Should -BeTrue -Because "the settings function lacks $key"
            }
        }

        It 'carries the stack isolation keys' {
            $script:functionSettings['Assets:FileSystem:PublicUrl'] | Should -BeLike '*://mgmt.dev.internal:8091/assets/'
            $script:functionSettings['ConnectionStrings:VirtoCommerce'] | Should -BeLike '*=VirtoCommerce_platform*'
        }
    }
}
