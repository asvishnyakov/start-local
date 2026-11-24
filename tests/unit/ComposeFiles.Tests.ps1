BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    # Short helper: 'yml' -> 'docker-compose.yml', 'platform.https.yml' -> 'docker-compose/platform.https.yml'
    function script:Compose {
        param([string[]]$Suffix)
        [string[]]@($Suffix | ForEach-Object { Get-ComposeFileName $_ })
    }
}

Describe 'ComposeFiles' -Tag 'Unit' {
    It 'default postgres list is canonical' {
        $expected = Compose 'yml', 'https.yml', 'postgres.yml',
        'platform.yml', 'platform.https.yml',
        'elasticsearch.yml', 'elasticsearch.https.yml',
        'kibana.yml', 'kibana.https.yml',
        'redis.yml',
        'frontend.yml', 'frontend.https.yml',
        'platform-postgres.yml',
        'platform-elasticsearch.yml', 'platform-elasticsearch.https.yml',
        'platform-redis.yml',
        'platform-frontend.yml',
        'kibana-elasticsearch.yml', 'kibana-elasticsearch.https.yml'
        $actual = Get-DefaultComposeFiles -Provider postgres
        $actual | Should -Be $expected
    }

    It 'default list without HTTPS has no overlay' {
        $list = Get-DefaultComposeFiles -Provider mysql -Https $false
        $list | Should -Not -Contain 'docker-compose/https.yml'
        $list | Where-Object { $_ -like '*.https.yml' } | Should -BeNullOrEmpty
        $list | Should -Contain 'docker-compose/platform-mysql.yml'
    }

    It 'normalization is idempotent (<Name>)' -TestCases @(
        @{ Name = 'default postgres'; Provider = 'postgres'; Https = $true; Suffix = $null; Modules = $false }
        @{ Name = 'default sqlserver, HTTP'; Provider = 'sqlserver'; Https = $false; Suffix = $null; Modules = $false }
        @{ Name = 'shuffled input'; Provider = $null; Https = $true; Suffix = @('frontend.yml', 'kibana.yml', 'https.yml', 'mysql.yml', 'platform.yml', 'elasticsearch.yml', 'yml'); Modules = $false }
        @{ Name = 'with modules'; Provider = $null; Https = $true; Suffix = @('yml', 'postgres.yml', 'platform.yml'); Modules = $true }
        @{ Name = 'unknown files'; Provider = $null; Https = $true; Suffix = @('x.yml', 'yml', 'my.override.yml', 'redis.yml'); Modules = $false }
        @{ Name = 'host platform'; Provider = $null; Https = $true; Suffix = @('yml', 'https.yml', 'postgres.yml', 'frontend.yml'); Modules = $false }
    ) {
        $files = if ($Provider) { Get-DefaultComposeFiles -Provider $Provider -Https $Https } else { Compose $Suffix }
        $once = Update-ComposeFileList -ComposeFiles $files -HasSourceModules $Modules
        $twice = Update-ComposeFileList -ComposeFiles $once -HasSourceModules $Modules
        $twice | Should -Be $once
    }

    It 'adds the platform-elasticsearch link only when both features are listed' {
        $both = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'platform.yml', 'elasticsearch.yml') -HasSourceModules $false
        $both | Should -Contain 'docker-compose/platform-elasticsearch.yml'

        $platformOnly = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'platform.yml') -HasSourceModules $false
        $platformOnly | Should -Not -Contain 'docker-compose/platform-elasticsearch.yml'

        $elasticsearchOnly = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'elasticsearch.yml', 'platform-elasticsearch.yml') -HasSourceModules $false
        $elasticsearchOnly | Should -Not -Contain 'docker-compose/platform-elasticsearch.yml'
    }

    It 'adds platform-modules only for a Docker platform with source modules' {
        $files = Compose 'yml', 'postgres.yml', 'platform.yml'
        (Update-ComposeFileList -ComposeFiles $files -HasSourceModules $true) | Should -Contain 'docker-compose/platform-modules.yml'
        (Update-ComposeFileList -ComposeFiles $files -HasSourceModules $false) | Should -Not -Contain 'docker-compose/platform-modules.yml'
        $hostPlatform = Compose 'yml', 'postgres.yml'
        (Update-ComposeFileList -ComposeFiles $hostPlatform -HasSourceModules $true) | Should -Not -Contain 'docker-compose/platform-modules.yml'
    }

    It 'lists every overlay iff https.yml is listed' {
        $https = Get-DefaultComposeFiles -Provider postgres
        $plain = Set-ComposeHttps -ComposeFiles $https -Enabled $false
        $plain | Should -Not -Contain 'docker-compose/https.yml'
        @($plain | Where-Object { $_ -like '*.https.yml' }) | Should -HaveCount 0
        $plain | Should -Contain 'docker-compose/platform.yml'

        (Set-ComposeHttps -ComposeFiles $plain -Enabled $true) | Should -Be $https
    }

    It 'does not list an overlay whose base file is not listed' {
        $files = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'https.yml', 'postgres.yml', 'platform.yml') -HasSourceModules $false
        $files | Should -Not -Contain 'docker-compose/elasticsearch.https.yml'
        $files | Should -Not -Contain 'docker-compose/frontend.https.yml'
        $files | Should -Contain 'docker-compose/platform.https.yml'
    }

    It 'skipping and re-adding elasticsearch keeps the HTTPS mode' {
        $start = Get-DefaultComposeFiles -Provider postgres
        $without = Set-ComposeFeature -ComposeFiles $start -Feature elasticsearch -Enabled $false -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings | Should -HaveCount 1
        $without | Should -Not -Contain 'docker-compose/elasticsearch.https.yml'
        $without | Should -Not -Contain 'docker-compose/platform-elasticsearch.https.yml'
        $without | Should -Not -Contain 'docker-compose/kibana.yml'

        $back = Set-ComposeFeature -ComposeFiles $without -Feature elasticsearch -Enabled $true
        $back | Should -Contain 'docker-compose/https.yml'
        $back | Should -Contain 'docker-compose/elasticsearch.https.yml'
        $back | Should -Contain 'docker-compose/platform-elasticsearch.https.yml'
    }

    It 'keeps unknown files after built-in files in their order' {
        $input = [string[]]@('my.override.yml', 'docker-compose/redis.yml', 'x.yml', 'docker-compose.yml', 'docker-compose/postgres.yml')
        $result = Update-ComposeFileList -ComposeFiles $input -HasSourceModules $false
        $result | Should -Be ([string[]]@('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/redis.yml', 'my.override.yml', 'x.yml'))
    }

    Context 'Resolve-DbProvider' {
        It 'returns the provider' {
            Resolve-DbProvider -ComposeFiles (Compose 'yml', 'mysql.yml') | Should -BeExactly 'mysql'
        }

        It 'returns $null with no provider' {
            Resolve-DbProvider -ComposeFiles (Compose 'yml', 'redis.yml') | Should -BeNullOrEmpty
        }

        It 'throws InvalidOperationException when two are listed' {
            { Resolve-DbProvider -ComposeFiles (Compose 'yml', 'mysql.yml', 'postgres.yml') } |
                Should -Throw -ExceptionType ([System.InvalidOperationException])
        }
    }

    It 'Get-ComposeFeatures reads every feature' {
        $features = Get-ComposeFeatures -ComposeFiles (Get-DefaultComposeFiles -Provider sqlserver)
        $features.Provider | Should -BeExactly 'sqlserver'
        $features.Platform | Should -BeTrue
        $features.Elasticsearch | Should -BeTrue
        $features.Kibana | Should -BeTrue
        $features.Redis | Should -BeTrue
        $features.Frontend | Should -BeTrue
        $features.Https | Should -BeTrue
    }

    It 'drops kibana with a warning without elasticsearch' {
        $result = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'kibana.yml') -HasSourceModules $false -WarningVariable warnings -WarningAction SilentlyContinue
        $result | Should -Not -Contain 'docker-compose/kibana.yml'
        $result | Should -Not -Contain 'docker-compose/kibana-elasticsearch.yml'
        $warnings | Should -HaveCount 1
        "$($warnings[0])" | Should -BeLike '*kibana*elasticsearch*'
    }

    It 'drops es-limited with a warning without elasticsearch' {
        $result = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'es-limited.yml') -HasSourceModules $false -WarningVariable warnings -WarningAction SilentlyContinue
        $result | Should -Not -Contain 'docker-compose/es-limited.yml'
        $warnings | Should -HaveCount 1
        "$($warnings[0])" | Should -BeLike '*es-limited*elasticsearch*'
    }

    It 'keeps es-limited after elasticsearch when elasticsearch is listed' {
        $result = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'es-limited.yml', 'postgres.yml', 'elasticsearch.yml') -HasSourceModules $false
        $result | Should -Be (Compose 'yml', 'postgres.yml', 'elasticsearch.yml', 'es-limited.yml')
    }

    It 'adds frontend-hostplatform when the frontend is listed without the platform' {
        $result = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'frontend.yml') -HasSourceModules $false
        $result | Should -Contain 'docker-compose/frontend-hostplatform.yml'
        $result | Should -Not -Contain 'docker-compose/platform-frontend.yml'
        $result[-1] | Should -BeExactly 'docker-compose/frontend-hostplatform.yml'

        $withPlatform = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'platform.yml', 'frontend.yml', 'frontend-hostplatform.yml') -HasSourceModules $false
        $withPlatform | Should -Not -Contain 'docker-compose/frontend-hostplatform.yml'
        $withPlatform | Should -Contain 'docker-compose/platform-frontend.yml'
    }

    It 'Set-ComposeProvider swaps the provider and its link' {
        $result = Set-ComposeProvider -ComposeFiles (Get-DefaultComposeFiles -Provider postgres) -Provider sqlserver
        $result | Should -Be (Get-DefaultComposeFiles -Provider sqlserver)
        $result | Should -Not -Contain 'docker-compose/platform-postgres.yml'
    }

    It 'Set-ComposeFeature preserves source modules and rejects unknown features' {
        $files = Update-ComposeFileList -ComposeFiles (Get-DefaultComposeFiles -Provider postgres) -HasSourceModules $true
        $files | Should -Contain 'docker-compose/platform-modules.yml'
        (Set-ComposeFeature -ComposeFiles $files -Feature redis -Enabled $false) | Should -Contain 'docker-compose/platform-modules.yml'
        { Set-ComposeFeature -ComposeFiles $files -Feature nope -Enabled $true } | Should -Throw
    }

    Context 'file list value' {
        It 'splits and joins with the separator' {
            $list = Get-ComposeFileList -Value ' docker-compose.yml ;docker-compose/postgres.yml;;'
            $list | Should -Be @('docker-compose.yml', 'docker-compose/postgres.yml')
            ConvertTo-ComposeFileValue -ComposeFiles $list | Should -BeExactly 'docker-compose.yml;docker-compose/postgres.yml'
            ConvertTo-ComposeFileValue -ComposeFiles $list -Separator ':' | Should -BeExactly 'docker-compose.yml:docker-compose/postgres.yml'
            (Get-ComposeFileList -Value 'a.yml:b.yml' -Separator ':') | Should -Be @('a.yml', 'b.yml')
        }

        It 'reads a hand-written backslash as the catalog''s forward slash' {
            $list = Get-ComposeFileList -Value 'docker-compose.yml;docker-compose\postgres.yml'
            $list | Should -Be @('docker-compose.yml', 'docker-compose/postgres.yml')
            (Get-ComposeFeatures -ComposeFiles $list).Provider | Should -Be 'postgres'
        }

        It 'returns an empty array for an empty value' {
            $list = Get-ComposeFileList -Value ''
            , $list | Should -BeOfType ([string[]])
            $list.Count | Should -Be 0
        }

        It 'returns a single file as an array' {
            $list = Get-ComposeFileList -Value 'docker-compose.yml'
            , $list | Should -BeOfType ([string[]])
            $list.Count | Should -Be 1
        }

        It 'chains an empty COMPOSE_FILE straight into the interface functions' {
            $empty = Get-ComposeFileList -Value ''
            (Update-ComposeFileList -ComposeFiles $empty -HasSourceModules $false) | Should -Be @('docker-compose.yml')
            Resolve-DbProvider -ComposeFiles $empty | Should -BeNullOrEmpty
            (Get-ComposeFeatures -ComposeFiles $empty).Platform | Should -BeFalse
            ConvertTo-ComposeFileValue -ComposeFiles $empty | Should -BeExactly ''
            (Set-ComposeProvider -ComposeFiles $empty -Provider mysql) | Should -Contain 'docker-compose/mysql.yml'
            (Set-ComposeHttps -ComposeFiles $empty -Enabled $true) | Should -Contain 'docker-compose/https.yml'
        }
    }

    It 'Get-ComposeProjectName matches the Compose rule (<Folder>)' -TestCases @(
        @{ Folder = 'VirtoLocal'; Expected = 'virtolocal' }
        @{ Folder = 'My Stack.v2'; Expected = 'mystackv2' }
        @{ Folder = '/home/user/_-Edge Case_'; Expected = 'edgecase_' }
        @{ Folder = '/home/user/VirtoLocal/'; Expected = 'virtolocal' }
    ) {
        Get-ComposeProjectName -FolderPath $Folder | Should -BeExactly $Expected
    }

    It 'Get-ComposeProjectName throws when nothing is left of the name' {
        { Get-ComposeProjectName -FolderPath '/home/user/.._a' } | Should -Not -Throw
        { Get-ComposeProjectName -FolderPath '/home/user/..' } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'Get-VolumePrefix and Get-SolutionProjectName use VOLUME_PREFIX, then COMPOSE_PROJECT_NAME, then the folder name' -ForEach @(
        @{ Lines = @('VOLUME_PREFIX=virto', 'COMPOSE_PROJECT_NAME=other'); Prefix = 'virto'; Project = 'other' }
        @{ Lines = @('VOLUME_PREFIX=', 'COMPOSE_PROJECT_NAME=other'); Prefix = 'other'; Project = 'other' }
        @{ Lines = @('VOLUME_PREFIX='); Prefix = 'my-stack'; Project = 'my-stack' }
        @{ Lines = $null; Prefix = 'my-stack'; Project = 'my-stack' }
    ) {
        $document = $null
        if ($Lines) {
            $path = Join-Path 'TestDrive:' "env-$([guid]::NewGuid().ToString('N'))"
            Set-Content -LiteralPath $path -Value $Lines
            $document = Read-EnvFile -Path $path
        }
        $folder = Join-Path 'TestDrive:' 'My-Stack'

        Get-VolumePrefix -Document $document -SolutionFolder $folder | Should -BeExactly $Prefix
        Get-SolutionProjectName -Document $document -SolutionFolder $folder | Should -BeExactly $Project
    }

    It 'Get-SolutionVolumeNames lists the nine volumes' {
        $volumes = Get-SolutionVolumeNames -Prefix virto
        $volumes | Should -Be @(
            'virto_postgres_data', 'virto_mysql_data', 'virto_mssql_data', 'virto_cms-content-data',
            'virto_assets-data', 'virto_modules-data', 'virto_esdata01', 'virto_redisdata', 'virto_certs')
    }

    It 'Get-SolutionImageNames lists the two images' {
        $images = Get-SolutionImageNames -ProjectName virtolocal
        $images | Should -Be @('vc-platform:virtolocal-latest', 'vc-frontend:virtolocal-latest')
    }

    Context 'stack roles' {
        BeforeAll {
            # What Get-ServicesStackInfo answers, without a folder: only what the functions under test read.
            function script:New-ServicesInfo {
                param(
                    [string]$Folder = '/work/svc',
                    [string]$Provider = 'postgres',
                    [bool]$Https = $true,
                    [bool]$Elasticsearch = $true,
                    [bool]$Redis = $true
                )

                [pscustomobject]@{
                    Folder      = $Folder
                    ProjectName = 'svc'
                    Features    = [pscustomobject]@{ Provider = $Provider; Https = $Https; Elasticsearch = $Elasticsearch; Redis = $Redis }
                    NetworkName = 'svc-shared'
                    CertsVolume = 'svc_certs'
                    EnvTable    = [ordered]@{}
                }
            }

            $script:Anchor = '../svc/docker-compose.yml'
        }

        Context 'a platform list' {
            It 'is anchor-first, gains the shared network and drops a standalone server file with a warning naming STACK_ROLE' {
                $files = Compose 'yml', 'postgres.yml', 'platform.yml'

                $result = Update-ComposeFileList $files $false -Role platform -ServicesAnchor $script:Anchor -WarningVariable warnings -WarningAction SilentlyContinue

                $result[0] | Should -BeExactly $script:Anchor
                $result[1] | Should -BeExactly 'docker-compose.yml'
                $result | Should -Contain 'docker-compose/shared-network.yml'
                $result | Should -Not -Contain 'docker-compose/postgres.yml'
                $warnings | Should -HaveCount 1
                "$($warnings[0])" | Should -BeLike '*postgres.yml*STACK_ROLE*platform*'
            }

            It 'warns naming STACK_ROLE for an out-of-role link' {
                $files = Compose 'yml', 'shared-network.yml', 'shared-postgres.yml', 'platform.yml', 'platform-postgres.yml'

                $result = Update-ComposeFileList $files $false -Role platform -ServicesAnchor $script:Anchor -WarningVariable warnings -WarningAction SilentlyContinue

                $result | Should -Not -Contain 'docker-compose/platform-postgres.yml'
                $warnings | Should -HaveCount 1
                "$($warnings[0])" | Should -BeLike '*platform-postgres.yml*STACK_ROLE*platform*'
            }

            It 'never lists the anchor again as a user file' {
                $result = Update-ComposeFileList (@($script:Anchor) + (Compose 'yml', 'shared-network.yml', 'shared-postgres.yml', 'platform.yml')) $false -Role platform -ServicesAnchor $script:Anchor

                @($result | Where-Object { $_ -ceq $script:Anchor }) | Should -HaveCount 1
                $result[0] | Should -BeExactly $script:Anchor
            }

            It 'lets the markers drive the links' {
                $files = Compose 'yml', 'shared-postgres.yml', 'shared-redis.yml', 'platform.yml'

                $result = Update-ComposeFileList $files $false -Role platform -ServicesAnchor $script:Anchor

                $result | Should -Contain 'docker-compose/platform-shared-postgres.yml'
                $result | Should -Contain 'docker-compose/platform-shared-redis.yml'
                $result | Should -Contain 'docker-compose/platform-shared.yml'
            }

            It 'has the markers of a source platform and no wiring' {
                $files = Compose 'yml', 'shared-postgres.yml', 'shared-redis.yml'

                $result = Update-ComposeFileList $files $false -Role platform -ServicesAnchor $script:Anchor

                $result | Should -Be (@($script:Anchor) + (Compose 'yml', 'shared-network.yml', 'shared-postgres.yml', 'shared-redis.yml'))
                Resolve-DbProvider $result | Should -BeExactly 'postgres'
                $features = Get-ComposeFeatures $result
                $features.Redis | Should -BeTrue
                $features.Shared | Should -BeTrue
                $features.Platform | Should -BeFalse
            }

            It 'is canonical for a full Docker list with HTTPS' {
                $files = Compose 'yml', 'https.yml', 'shared-postgres.yml', 'platform.yml', 'shared-elasticsearch.yml', 'shared-redis.yml', 'frontend.yml'

                $result = Update-ComposeFileList $files $false -Role platform -ServicesAnchor $script:Anchor -ComposeVersion '5.7.1'

                $result | Should -Be (@($script:Anchor) + (Compose 'yml', 'https.yml', 'shared-network.yml', 'shared-postgres.yml',
                        'platform.yml', 'platform.https.yml', 'shared-elasticsearch.yml', 'shared-redis.yml', 'frontend.yml', 'frontend.https.yml',
                        'shared-certs.yml',
                        'platform-shared.yml', 'platform-shared.https.yml', 'platform-shared-alias.yml', 'platform-shared-postgres.yml',
                        'platform-shared-elasticsearch.yml', 'platform-shared-elasticsearch.https.yml', 'platform-shared-redis.yml',
                        'platform-frontend.yml'))
            }

            It 'keeps the shared links apart from the standalone ones' {
                $files = Compose 'yml', 'shared-postgres.yml', 'platform.yml', 'elasticsearch.yml', 'redis.yml', 'kibana.yml', 'platform-postgres.yml'

                $result = Update-ComposeFileList $files $false -Role platform -ServicesAnchor $script:Anchor -WarningAction SilentlyContinue

                @($result | Where-Object { $_ -match '/(elasticsearch|redis|kibana|platform-postgres|platform-redis)' }) | Should -HaveCount 0
            }

            It 'is idempotent' {
                $generated = Compose 'platform-peers.yml'
                $once = Update-ComposeFileList (Compose 'yml', 'https.yml', 'shared-mysql.yml', 'platform.yml', 'shared-redis.yml', 'frontend.yml') $true -Role platform -ServicesAnchor $script:Anchor -GeneratedFiles $generated
                $twice = Update-ComposeFileList $once $true -Role platform -ServicesAnchor $script:Anchor -GeneratedFiles $generated

                $twice | Should -Be $once
                $once | Should -Contain 'docker-compose/platform-peers.yml'
                $once | Should -Contain 'docker-compose/platform-modules.yml'
            }

            It 'emits a generated link only when it is asked for, and only with platform.yml' {
                $files = Compose 'yml', 'shared-postgres.yml', 'platform.yml'

                $none = Update-ComposeFileList $files $false -Role platform -ServicesAnchor $script:Anchor
                $none | Should -Not -Contain 'docker-compose/platform-peers.yml'
                $none | Should -Not -Contain 'docker-compose/platform-extra-ca.yml'

                $both = Update-ComposeFileList $files $false -Role platform -ServicesAnchor $script:Anchor -GeneratedFiles (Compose 'platform-extra-ca.yml', 'platform-peers.yml')
                $both | Should -Contain 'docker-compose/platform-peers.yml'
                $both | Should -Contain 'docker-compose/platform-extra-ca.yml'

                $noPlatform = Update-ComposeFileList (Compose 'yml', 'shared-postgres.yml') $false -Role platform -ServicesAnchor $script:Anchor -GeneratedFiles (Compose 'platform-peers.yml')
                $noPlatform | Should -Not -Contain 'docker-compose/platform-peers.yml'
            }

            It 'adds the certificates link only with HTTPS' {
                $http = Update-ComposeFileList (Compose 'yml', 'shared-postgres.yml', 'platform.yml') $false -Role platform -ServicesAnchor $script:Anchor
                $http | Should -Not -Contain 'docker-compose/shared-certs.yml'

                $https = Update-ComposeFileList (Compose 'yml', 'https.yml', 'shared-postgres.yml') $false -Role platform -ServicesAnchor $script:Anchor
                $https | Should -Contain 'docker-compose/shared-certs.yml'
            }
        }

        Context 'a services list' {
            It 'drops platform.yml and frontend.yml, adds the network and one link per listed server' {
                $files = Compose 'yml', 'https.yml', 'postgres.yml', 'platform.yml', 'elasticsearch.yml', 'kibana.yml', 'redis.yml', 'frontend.yml'

                $result = Update-ComposeFileList $files $false -Role services -WarningVariable warnings -WarningAction SilentlyContinue

                $result | Should -Be (Compose 'yml', 'https.yml', 'services-network.yml', 'postgres.yml', 'elasticsearch.yml', 'elasticsearch.https.yml',
                    'kibana.yml', 'kibana.https.yml', 'redis.yml',
                    'services-database.yml', 'services-elasticsearch.yml', 'services-redis.yml',
                    'kibana-elasticsearch.yml', 'kibana-elasticsearch.https.yml')
                $warnings | Should -HaveCount 2
                ($warnings -join "`n") | Should -BeLike '*platform.yml*STACK_ROLE*'
                ($warnings -join "`n") | Should -BeLike '*frontend.yml*STACK_ROLE*'
            }

            It 'adds the Elasticsearch and Redis links only for a listed server' {
                $result = Update-ComposeFileList (Compose 'yml', 'mysql.yml') $false -Role services

                $result | Should -Be (Compose 'yml', 'services-network.yml', 'mysql.yml', 'services-database.yml')
            }

            It 'is idempotent' {
                $once = Update-ComposeFileList (Compose 'yml', 'https.yml', 'sqlserver.yml', 'elasticsearch.yml', 'es-limited.yml', 'redis.yml') $false -Role services
                (Update-ComposeFileList $once $false -Role services) | Should -Be $once
            }

            It 'drops a shared marker with a warning' {
                $result = Update-ComposeFileList (Compose 'yml', 'postgres.yml', 'shared-postgres.yml') $false -Role services -WarningVariable warnings -WarningAction SilentlyContinue

                $result | Should -Not -Contain 'docker-compose/shared-postgres.yml'
                $warnings | Should -HaveCount 1
            }
        }

        Context 'a standalone list' {
            It 'drops a role-only file with a warning, and keeps the rest' {
                $files = Compose 'yml', 'postgres.yml', 'platform.yml', 'shared-network.yml', 'services-network.yml'

                $result = Update-ComposeFileList $files $false -WarningVariable warnings -WarningAction SilentlyContinue

                $result | Should -Be (Compose 'yml', 'postgres.yml', 'platform.yml', 'platform-postgres.yml')
                $warnings | Should -HaveCount 2
                ($warnings -join "`n") | Should -BeLike '*STACK_ROLE*'
            }

            It 'never gets the alias file or a shared link' {
                $result = Update-ComposeFileList (Compose 'yml', 'postgres.yml', 'platform.yml', 'platform-shared-alias.yml', 'platform-shared.yml') $false -ComposeVersion '5.8.0' -WarningAction SilentlyContinue

                @($result | Where-Object { $_ -like '*shared*' }) | Should -HaveCount 0
            }

            It 'warns naming STACK_ROLE for an out-of-role HTTPS overlay' {
                $result = Update-ComposeFileList (Compose 'yml', 'https.yml', 'postgres.yml', 'platform-shared.https.yml') $false -WarningVariable warnings -WarningAction SilentlyContinue

                $result | Should -Not -Contain 'docker-compose/platform-shared.https.yml'
                @($warnings | Where-Object { "$_" -like '*platform-shared.https.yml*STACK_ROLE*' }) | Should -HaveCount 1
            }

            It 'warns naming STACK_ROLE for an out-of-role alias link' {
                $result = Update-ComposeFileList (Compose 'yml', 'postgres.yml', 'platform.yml', 'platform-shared-alias.yml') $false -ComposeVersion '5.8.0' -WarningVariable warnings -WarningAction SilentlyContinue

                $result | Should -Not -Contain 'docker-compose/platform-shared-alias.yml'
                @($warnings | Where-Object { "$_" -like '*platform-shared-alias.yml*STACK_ROLE*' }) | Should -HaveCount 1
            }

            It 'rejects an unknown role' {
                { Update-ComposeFileList (Compose 'yml') $false -Role tenant } | Should -Throw
            }
        }

        # Review Focus 7 (P19): a Compose below 5.7.0 rejects use_service_name_alias.
        Context 'the alias file (P19)' {
            BeforeAll {
                $script:Alias = Get-ComposeFileName 'platform-shared-alias.yml'
                $script:PlatformList = Compose 'yml', 'shared-postgres.yml', 'platform.yml'
                function script:Get-AliasList {
                    param([string[]]$Files = $script:PlatformList, [string]$Version = '', [string]$Role = 'platform')

                    $anchor = if ($Role -eq 'platform') { $script:Anchor } else { '' }
                    Update-ComposeFileList $Files $false -Role $Role -ServicesAnchor $anchor -ComposeVersion $Version -WarningAction SilentlyContinue
                }
            }

            It 'is added after platform-shared.yml on Compose <Version>' -ForEach @(@{ Version = '5.7.0' }, @{ Version = '5.7.1' }, @{ Version = '6.0.0' }) {
                $result = Get-AliasList -Version $Version

                $result | Should -Contain $script:Alias
                $result.IndexOf($script:Alias) | Should -BeGreaterThan $result.IndexOf((Get-ComposeFileName 'platform-shared.yml'))
            }

            It 'is dropped with no warning on Compose <Version>' -ForEach @(@{ Version = '5.6.1' }, @{ Version = '2.24.6' }) {
                $listed = Get-AliasList -Version '5.7.1'
                $result = Update-ComposeFileList $listed $false -Role platform -ServicesAnchor $script:Anchor -ComposeVersion $Version -WarningVariable warnings -WarningAction SilentlyContinue

                $result | Should -Not -Contain $script:Alias
                $warnings | Should -HaveCount 0
            }

            It 'is kept when listed and the version is unknown, and never added' {
                $listed = Get-AliasList -Version '5.7.1'
                (Get-AliasList -Files $listed -Version '') | Should -Contain $script:Alias
                (Get-AliasList -Files $script:PlatformList -Version '') | Should -Not -Contain $script:Alias
            }

            It 'is never emitted without platform.yml' {
                $source = Compose 'yml', 'shared-postgres.yml'
                (Get-AliasList -Files ($source + $script:Alias) -Version '5.8.0') | Should -Not -Contain $script:Alias
                (Get-AliasList -Files ($source + $script:Alias) -Version '') | Should -Not -Contain $script:Alias
            }

            It 'is never emitted in a standalone list' {
                $standalone = Compose 'yml', 'postgres.yml', 'platform.yml'
                (Get-AliasList -Files $standalone -Version '5.8.0' -Role '') | Should -Not -Contain $script:Alias
                (Get-AliasList -Files ($standalone + $script:Alias) -Version '' -Role '') | Should -Not -Contain $script:Alias
            }
        }

        Context 'Get-ComposeFeatures and Resolve-DbProvider' {
            It 'reads the shared markers as the servers a platform stack uses' {
                $features = Get-ComposeFeatures (Compose 'yml', 'shared-network.yml', 'shared-mysql.yml', 'shared-elasticsearch.yml')

                $features.Provider | Should -BeExactly 'mysql'
                $features.Elasticsearch | Should -BeTrue
                $features.Redis | Should -BeFalse
                $features.Shared | Should -BeTrue
                $features.Services | Should -BeFalse
            }

            It 'reports the services network' {
                $features = Get-ComposeFeatures (Compose 'yml', 'services-network.yml', 'postgres.yml')
                $features.Services | Should -BeTrue
                $features.Shared | Should -BeFalse
            }

            It 'does not take a shared Elasticsearch marker for a provider' {
                Resolve-DbProvider (Compose 'yml', 'shared-elasticsearch.yml') | Should -BeNullOrEmpty
            }

            It 'is the same provider when a provider file and its marker are both listed' {
                Resolve-DbProvider (Compose 'yml', 'postgres.yml', 'shared-postgres.yml') | Should -BeExactly 'postgres'
            }

            It 'still throws for two different providers, markers included' {
                { Resolve-DbProvider (Compose 'yml', 'shared-postgres.yml', 'shared-mysql.yml') } |
                    Should -Throw -ExceptionType ([System.InvalidOperationException])
            }
        }

        Context 'Set-ComposeFeature in a platform list' {
            BeforeAll {
                $script:Docker = Update-ComposeFileList (Compose 'yml', 'https.yml', 'shared-postgres.yml', 'platform.yml', 'shared-elasticsearch.yml', 'shared-redis.yml', 'frontend.yml') $false `
                    -Role platform -ServicesAnchor $script:Anchor -GeneratedFiles (Compose 'platform-peers.yml')
            }

            It 'maps <Feature> to its shared marker, with no warning' -ForEach @(
                @{ Feature = 'elasticsearch'; Marker = 'shared-elasticsearch.yml'; Wiring = 'platform-shared-elasticsearch.yml' }
                @{ Feature = 'redis'; Marker = 'shared-redis.yml'; Wiring = 'platform-shared-redis.yml' }
            ) {
                $without = Set-ComposeFeature $script:Docker $Feature $false -Role platform -WarningVariable warnings -WarningAction SilentlyContinue

                $without | Should -Not -Contain (Get-ComposeFileName $Marker)
                $without | Should -Not -Contain (Get-ComposeFileName $Wiring)
                $warnings | Should -HaveCount 0
                (Set-ComposeFeature $without $Feature $true -Role platform) | Should -Be $script:Docker
            }

            It 'keeps the anchor first and the generated files listed through a change' {
                $result = Set-ComposeFeature $script:Docker 'frontend' $false -Role platform

                $result[0] | Should -BeExactly $script:Anchor
                $result | Should -Contain 'docker-compose/platform-peers.yml'
                $result | Should -Not -Contain 'docker-compose/frontend.yml'
            }

            It 'keeps a listed alias file through a change' {
                $listed = Update-ComposeFileList $script:Docker $false -Role platform -ServicesAnchor $script:Anchor -ComposeVersion '5.7.1'
                (Set-ComposeFeature $listed 'redis' $false -Role platform) | Should -Contain 'docker-compose/platform-shared-alias.yml'
            }

            It 'lists the HTTPS overlay and the certificates link with HTTPS' {
                $script:Docker | Should -Contain 'docker-compose/platform-shared-elasticsearch.https.yml'
                $script:Docker | Should -Contain 'docker-compose/shared-certs.yml'
            }

            It 'throws for a feature the role has no file for' {
                { Set-ComposeFeature $script:Docker 'platform' $true -Role services } | Should -Throw -ExceptionType ([System.ArgumentException])
            }
        }

        Context 'Set-ComposeProvider and Set-ComposeHttps in a services list' {
            It 'swaps the provider and its link' {
                $list = Update-ComposeFileList (Compose 'yml', 'postgres.yml', 'redis.yml') $false -Role services

                $result = Set-ComposeProvider $list 'mysql' -Role services

                $result | Should -Be (Compose 'yml', 'services-network.yml', 'mysql.yml', 'redis.yml', 'services-database.yml', 'services-redis.yml')
            }

            It 'toggles HTTPS' {
                $list = Update-ComposeFileList (Compose 'yml', 'postgres.yml', 'elasticsearch.yml') $false -Role services

                $https = Set-ComposeHttps $list $true -Role services
                $https | Should -Contain 'docker-compose/https.yml'
                $https | Should -Contain 'docker-compose/elasticsearch.https.yml'
                (Set-ComposeHttps $https $false -Role services) | Should -Be $list
            }
        }

        Context 'Get-DefaultComposeFiles for a services stack' {
            It 'lists the servers and no platform' {
                $result = Get-DefaultComposeFiles -Provider postgres -Role services

                $result | Should -Be (Compose 'yml', 'https.yml', 'services-network.yml', 'postgres.yml', 'elasticsearch.yml', 'elasticsearch.https.yml',
                    'kibana.yml', 'kibana.https.yml', 'redis.yml', 'services-database.yml', 'services-elasticsearch.yml', 'services-redis.yml',
                    'kibana-elasticsearch.yml', 'kibana-elasticsearch.https.yml')
            }
        }

        Context 'Get-ServicesAnchorEntry' {
            It 'is the relative path with forward slashes, ending with docker-compose.yml' {
                $solution = Join-Path $TestDrive 'work/platform'
                $services = Join-Path $TestDrive 'work/svc'

                Get-ServicesAnchorEntry -ServicesFolder $services -SolutionFolder $solution | Should -BeExactly '../svc/docker-compose.yml'
            }

            It 'is a child path for a services folder below the platform folder' {
                $solution = Join-Path $TestDrive 'work/platform'
                $services = Join-Path $solution 'svc'

                Get-ServicesAnchorEntry -ServicesFolder $services -SolutionFolder $solution | Should -BeExactly 'svc/docker-compose.yml'
            }

            It 'ignores a trailing separator' {
                $solution = Join-Path $TestDrive 'work/platform'
                $services = (Join-Path $TestDrive 'work/svc') + [System.IO.Path]::DirectorySeparatorChar

                Get-ServicesAnchorEntry -ServicesFolder $services -SolutionFolder $solution | Should -BeExactly '../svc/docker-compose.yml'
            }

            It 'reads a relative services folder against the solution folder' {
                $solution = Join-Path $TestDrive 'work/platform'

                Get-ServicesAnchorEntry -ServicesFolder '../svc' -SolutionFolder $solution | Should -BeExactly '../svc/docker-compose.yml'
            }
        }

        Context 'Sync-PlatformComposeFiles' {
            BeforeAll {
                $script:Solution = Join-Path $TestDrive 'work/platform'
                $script:ServicesFolder = Join-Path $TestDrive 'work/svc'
            }

            It 'follows the services stack''s provider and HTTPS mode' {
                $files = Update-ComposeFileList (Compose 'yml', 'shared-mysql.yml', 'platform.yml', 'frontend.yml') $false -Role platform -ServicesAnchor $script:Anchor
                $info = New-ServicesInfo -Folder $script:ServicesFolder -Provider sqlserver -Https $true

                $result = Sync-PlatformComposeFiles $files $info $script:Solution

                $result[0] | Should -BeExactly $script:Anchor
                $result | Should -Contain 'docker-compose/shared-sqlserver.yml'
                $result | Should -Not -Contain 'docker-compose/shared-mysql.yml'
                $result | Should -Not -Contain 'docker-compose/platform-shared-mysql.yml'
                $result | Should -Contain 'docker-compose/platform-shared-sqlserver.yml'
                $result | Should -Contain 'docker-compose/https.yml'
                $result | Should -Contain 'docker-compose/platform.https.yml'
                $result | Should -Contain 'docker-compose/shared-certs.yml'

                $plain = Sync-PlatformComposeFiles $result (New-ServicesInfo -Folder $script:ServicesFolder -Provider sqlserver -Https $false) $script:Solution
                $plain | Should -Not -Contain 'docker-compose/https.yml'
                @($plain | Where-Object { $_ -like '*.https.yml' -or $_ -like '*certs*' }) | Should -HaveCount 0
            }

            It 'keeps a user-removed shared-elasticsearch.yml removed, and a listed one listed' {
                $without = Update-ComposeFileList (Compose 'yml', 'https.yml', 'shared-postgres.yml', 'platform.yml', 'shared-redis.yml') $false -Role platform -ServicesAnchor $script:Anchor
                $info = New-ServicesInfo -Folder $script:ServicesFolder -Elasticsearch $true -Redis $true

                $result = Sync-PlatformComposeFiles $without $info $script:Solution
                $result | Should -Not -Contain 'docker-compose/shared-elasticsearch.yml'
                $result | Should -Contain 'docker-compose/shared-redis.yml'

                $with = Sync-PlatformComposeFiles (Compose 'yml', 'shared-postgres.yml', 'shared-elasticsearch.yml') $info $script:Solution
                $with | Should -Contain 'docker-compose/shared-elasticsearch.yml'
            }

            It 'does not add a marker for a server the services stack lacks' {
                $files = Update-ComposeFileList (Compose 'yml', 'shared-postgres.yml', 'platform.yml') $false -Role platform -ServicesAnchor $script:Anchor
                $info = New-ServicesInfo -Folder $script:ServicesFolder -Elasticsearch $false -Redis $false

                $result = Sync-PlatformComposeFiles $files $info $script:Solution

                $result | Should -Not -Contain 'docker-compose/shared-elasticsearch.yml'
                $result | Should -Not -Contain 'docker-compose/shared-redis.yml'
            }

            It 'replaces an old anchor and never lists the services stack''s server files' {
                $old = @('../old/docker-compose.yml') + (Compose 'yml', 'postgres.yml', 'redis.yml', 'elasticsearch.yml', 'shared-postgres.yml', 'platform.yml')

                $result = Sync-PlatformComposeFiles $old (New-ServicesInfo -Folder $script:ServicesFolder) $script:Solution -WarningAction SilentlyContinue

                $result[0] | Should -BeExactly '../svc/docker-compose.yml'
                $result | Should -Not -Contain '../old/docker-compose.yml'
                @($result | Where-Object { $_ -match '/(postgres|redis|elasticsearch|kibana)\.' }) | Should -HaveCount 0
            }

            It 'is idempotent and keeps the user''s own files' {
                $files = (Update-ComposeFileList (Compose 'yml', 'shared-postgres.yml', 'platform.yml') $false -Role platform -ServicesAnchor $script:Anchor) + 'my.override.yml'
                $info = New-ServicesInfo -Folder $script:ServicesFolder -Https $false

                $once = Sync-PlatformComposeFiles $files $info $script:Solution
                (Sync-PlatformComposeFiles $once $info $script:Solution) | Should -Be $once
                $once[-1] | Should -BeExactly 'my.override.yml'
            }

            It 'keeps the generated files listed' {
                $files = Update-ComposeFileList (Compose 'yml', 'shared-postgres.yml', 'platform.yml') $true -Role platform -ServicesAnchor $script:Anchor -GeneratedFiles (Compose 'platform-peers.yml', 'platform-extra-ca.yml')

                $result = Sync-PlatformComposeFiles $files (New-ServicesInfo -Folder $script:ServicesFolder) $script:Solution

                $result | Should -Contain 'docker-compose/platform-modules.yml'
                $result | Should -Contain 'docker-compose/platform-peers.yml'
                $result | Should -Contain 'docker-compose/platform-extra-ca.yml'
            }
        }

        Context 'Get-DefaultPlatformComposeFiles and Update-EnvForRole (P16)' {
            BeforeAll {
                $script:Solution = Join-Path $TestDrive 'work/platform'
                $script:ServicesFolder = Join-Path $TestDrive 'work/svc'
                $script:FullServices = New-ServicesInfo -Folder $script:ServicesFolder -Provider postgres -Https $true -Elasticsearch $true -Redis $true
                $script:FirstRun = Compose 'yml', 'https.yml', 'shared-network.yml', 'shared-postgres.yml', 'platform.yml', 'platform.https.yml',
                'shared-elasticsearch.yml', 'shared-redis.yml', 'frontend.yml', 'frontend.https.yml', 'shared-certs.yml',
                'platform-shared.yml', 'platform-shared.https.yml', 'platform-shared-postgres.yml',
                'platform-shared-elasticsearch.yml', 'platform-shared-elasticsearch.https.yml', 'platform-shared-redis.yml', 'platform-frontend.yml'
            }

            It 'fills a Docker platform list from the services stack' {
                $result = Get-DefaultPlatformComposeFiles $script:FullServices 'docker' $script:Solution

                $result | Should -Be (@('../svc/docker-compose.yml') + $script:FirstRun)
            }

            It 'lists no Docker platform for a platform from source, and its storefront gets the host link' {
                $result = Get-DefaultPlatformComposeFiles $script:FullServices 'source' $script:Solution

                $result | Should -Not -Contain 'docker-compose/platform.yml'
                $result | Should -Not -Contain 'docker-compose/platform-shared.yml'
                $result | Should -Contain 'docker-compose/frontend.yml'
                $result | Should -Contain 'docker-compose/frontend-hostplatform.yml'
                $result | Should -Contain 'docker-compose/shared-redis.yml'
            }

            It 'lists only the markers of the servers the services stack runs, and HTTP when it has none' {
                $info = New-ServicesInfo -Folder $script:ServicesFolder -Provider mysql -Https $false -Elasticsearch $false -Redis $true

                $result = Get-DefaultPlatformComposeFiles $info 'docker' $script:Solution

                $result | Should -Contain 'docker-compose/shared-mysql.yml'
                $result | Should -Contain 'docker-compose/shared-redis.yml'
                $result | Should -Not -Contain 'docker-compose/shared-elasticsearch.yml'
                $result | Should -Not -Contain 'docker-compose/https.yml'
                $result | Should -Not -Contain 'docker-compose/shared-certs.yml'
            }

            Context 'with a services folder on disk' {
                BeforeEach {
                    $script:Root = Join-Path $TestDrive "first-run-$([guid]::NewGuid().ToString('N'))"
                    $script:RunServices = Join-Path $script:Root 'svc'
                    $script:RunPlatform = Join-Path $script:Root 'platform'
                    $null = New-Item -ItemType Directory -Path $script:RunServices, $script:RunPlatform
                    $servicesFiles = Get-DefaultComposeFiles -Provider postgres -Role services
                    Set-Content -LiteralPath (Join-Path $script:RunServices '.env') -Value @('STACK_ROLE=services', "COMPOSE_FILE=$(ConvertTo-ComposeFileValue $servicesFiles)")
                    $script:Template = Read-EnvFile (Join-Path $PSScriptRoot '../../.env.example')
                    $script:Document = Read-EnvFile (Join-Path $PSScriptRoot '../../.env.example')
                    Set-EnvValue -Document $script:Document -Key 'STACK_ROLE' -Value 'platform'
                    Set-EnvValue -Document $script:Document -Key 'SERVICES_FOLDER' -Value '../svc'
                }

                It 'fills an empty COMPOSE_FILE, and the skip switch then removes the marker with no warning' {
                    $changed = Update-EnvForRole -Document $script:Document -SolutionFolder $script:RunPlatform -Template $script:Template

                    $changed | Should -Contain 'COMPOSE_FILE'
                    $files = Get-EnvComposeFiles $script:Document
                    $files | Should -Be (@('../svc/docker-compose.yml') + $script:FirstRun)

                    $warnings = Update-EnvFromOptions -Document $script:Document -Bound @{ skipElasticsearch = [switch]$true } -WarningVariable streamWarnings -WarningAction SilentlyContinue
                    @($warnings) | Should -HaveCount 0
                    $streamWarnings | Should -HaveCount 0
                    $after = Get-EnvComposeFiles $script:Document
                    $after | Should -Not -Contain 'docker-compose/shared-elasticsearch.yml'
                    $after | Should -Not -Contain 'docker-compose/platform-shared-elasticsearch.yml'
                    $after | Should -Not -Contain 'docker-compose/platform-shared-elasticsearch.https.yml'
                    $after[0] | Should -BeExactly '../svc/docker-compose.yml'
                    $after | Should -Contain 'docker-compose/shared-redis.yml'
                }

                It 'leaves a source platform without platform.yml' {
                    Set-EnvValue -Document $script:Document -Key 'PLATFORM_SOURCE_PATH' -Value '/src/vc-platform'

                    $null = Update-EnvForRole -Document $script:Document -SolutionFolder $script:RunPlatform -Template $script:Template

                    (Get-EnvComposeFiles $script:Document) | Should -Not -Contain 'docker-compose/platform.yml'
                }

                It 'changes nothing on a second call' {
                    $null = Update-EnvForRole -Document $script:Document -SolutionFolder $script:RunPlatform -Template $script:Template
                    $before = ConvertTo-EnvText $script:Document

                    $second = Update-EnvForRole -Document $script:Document -SolutionFolder $script:RunPlatform -Template $script:Template

                    @($second).Count | Should -Be 0
                    ConvertTo-EnvText $script:Document | Should -BeExactly $before
                }

                It 'keeps a COMPOSE_FILE the user wrote' {
                    Set-EnvValue -Document $script:Document -Key 'COMPOSE_FILE' -Value '../svc/docker-compose.yml;docker-compose.yml'

                    $changed = Update-EnvForRole -Document $script:Document -SolutionFolder $script:RunPlatform -Template $script:Template

                    $changed | Should -Not -Contain 'COMPOSE_FILE'
                    Get-EnvValue -Document $script:Document -Key 'COMPOSE_FILE' | Should -BeExactly '../svc/docker-compose.yml;docker-compose.yml'
                }

                It 'leaves COMPOSE_FILE empty when the services folder is not a services stack' {
                    Set-Content -LiteralPath (Join-Path $script:RunServices '.env') -Value @('STACK_ROLE=')

                    $changed = Update-EnvForRole -Document $script:Document -SolutionFolder $script:RunPlatform -Template $script:Template

                    $changed | Should -Not -Contain 'COMPOSE_FILE'
                    Get-EnvValue -Document $script:Document -Key 'COMPOSE_FILE' | Should -BeNullOrEmpty
                }

                It 'leaves COMPOSE_FILE empty when the services stack names no database provider' {
                    Set-Content -LiteralPath (Join-Path $script:RunServices '.env') -Value @('STACK_ROLE=services', 'COMPOSE_FILE=')

                    $changed = Update-EnvForRole -Document $script:Document -SolutionFolder $script:RunPlatform -Template $script:Template

                    $changed | Should -Not -Contain 'COMPOSE_FILE'
                    Get-EnvValue -Document $script:Document -Key 'COMPOSE_FILE' | Should -BeNullOrEmpty
                }

                It 'leaves COMPOSE_FILE empty when SERVICES_FOLDER is empty' {
                    Set-EnvValue -Document $script:Document -Key 'SERVICES_FOLDER' -Value ''

                    $null = Update-EnvForRole -Document $script:Document -SolutionFolder $script:RunPlatform -Template $script:Template

                    Get-EnvValue -Document $script:Document -Key 'COMPOSE_FILE' | Should -BeNullOrEmpty
                }
            }
        }

        Context 'Get-KeepDataDeletePaths' {
            It 'neither keeps nor deletes the anchor, and touches nothing outside the folder' {
                $root = Join-Path $TestDrive "keep-$([guid]::NewGuid().ToString('N'))"
                $folder = Join-Path $root 'platform'
                $null = New-Item -ItemType Directory -Path $folder, (Join-Path $root 'svc')
                $null = New-Item -ItemType File -Path (Join-Path $folder '.env'), (Join-Path $folder 'junk.txt'), (Join-Path $root 'svc/docker-compose.yml')
                $document = Read-EnvFile (Join-Path $PSScriptRoot '../../.env.example')
                Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value '../svc/docker-compose.yml;docker-compose.yml'

                $paths = Get-KeepDataDeletePaths -Folder $folder -Document $document

                @($paths) | Should -Be @((Join-Path $folder 'junk.txt'))
                (Test-Path -LiteralPath (Join-Path $root 'svc/docker-compose.yml')) | Should -BeTrue
            }

            It 'does not treat a sibling folder with the same prefix as inside' {
                $root = Join-Path $TestDrive "prefix-$([guid]::NewGuid().ToString('N'))"
                $folder = Join-Path $root 'platform'
                $null = New-Item -ItemType Directory -Path $folder, (Join-Path $root 'platform2')
                $null = New-Item -ItemType File -Path (Join-Path $folder '.env'), (Join-Path $folder 'junk.txt'), (Join-Path $folder 'my.override.yml')
                $document = Read-EnvFile (Join-Path $PSScriptRoot '../../.env.example')
                Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value '../platform2/docker-compose.yml;my.override.yml'

                $paths = Get-KeepDataDeletePaths -Folder $folder -Document $document

                @($paths) | Should -Be @((Join-Path $folder 'junk.txt'))
            }
        }
    }
}
