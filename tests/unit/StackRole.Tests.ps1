BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    $script:ExamplePath = Join-Path $PSScriptRoot '../../.env.example'

    function script:New-RoleFolder {
        # An empty folder named $Name under the test drive; returns its path.
        param([string]$Name)

        $folder = Join-Path $TestDrive $Name
        $null = New-Item -ItemType Directory -Path $folder -Force
        $folder
    }

    function script:New-PlatformDocument {
        # A platform .env made from .env.example: the role set, the rest as the template has it.
        param([hashtable]$Values = @{})

        $document = Read-EnvFile $script:ExamplePath
        Set-EnvValue -Document $document -Key 'STACK_ROLE' -Value 'platform'
        foreach ($key in $Values.Keys) {
            Set-EnvValue -Document $document -Key $key -Value ([string]$Values[$key])
        }
        $document
    }
}

Describe 'StackRole' -Tag 'Unit' {
    Context 'Get-StackRole' {
        It 'is <Expected> for STACK_ROLE "<Value>"' -ForEach @(
            @{ Value = ''; Expected = '' }
            @{ Value = 'services'; Expected = 'services' }
            @{ Value = 'platform'; Expected = 'platform' }
            @{ Value = ' platform '; Expected = 'platform' }
        ) {
            Get-StackRole -EnvValues @{ STACK_ROLE = $Value } | Should -BeExactly $Expected
        }

        It 'is empty when the key is missing' {
            Get-StackRole -EnvValues @{} | Should -BeExactly ''
        }

        It 'throws naming STACK_ROLE for "<Value>" (the case matters, like SKIP_PLATFORM)' -ForEach @(
            @{ Value = 'Platform' }
            @{ Value = 'SERVICES' }
            @{ Value = 'standalone' }
        ) {
            { Get-StackRole -EnvValues @{ STACK_ROLE = $Value } } |
                Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*STACK_ROLE*'
        }
    }

    Context 'Get-ServicesOwnedKeys' {
        It 'lists the secrets, the server versions and ports, and the two keys the services start writes' {
            $expected = @($script:SecretKeys) + @(
                'PGSQL_VERSION', 'PGSQL_PORT', 'MYSQL_VERSION', 'MYSQL_PORT', 'MSSQL_VERSION', 'MSSQL_PORT',
                'STACK_VERSION', 'ES_PORT', 'KIBANA_PORT', 'ES_MEM_LIMIT', 'REDIS_PORT', 'SERVICES_NETWORK_NAME', 'SERVICES_CERTS_VOLUME'
            )
            (Get-ServicesOwnedKeys) | Should -Be $expected
        }

        It 'owns none of the keys a platform stack keeps' {
            $owned = Get-ServicesOwnedKeys
            foreach ($key in 'PLATFORM_PORT', 'FRONTEND_PORT', 'VOLUME_PREFIX', 'BIND_ADDRESS', 'COMPOSE_FILE', 'SEARCH_PROVIDER', 'REDIS_DATABASE') {
                $owned | Should -Not -Contain $key
            }
        }
    }

    Context 'Resolve-ServicesFolder' {
        It 'resolves a relative value against the solution folder' {
            $solution = New-RoleFolder 'resolve/platform'
            $expected = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $solution) 'svc'))

            Resolve-ServicesFolder -Value '../svc' -SolutionFolder $solution | Should -BeExactly $expected
        }

        It 'keeps an absolute value and drops a trailing separator' {
            $solution = New-RoleFolder 'resolve-abs/platform'
            $absolute = New-RoleFolder 'resolve-abs/elsewhere'

            Resolve-ServicesFolder -Value "$absolute/" -SolutionFolder $solution | Should -BeExactly $absolute
        }
    }

    Context 'Get-ServicesStackInfo' {
        BeforeEach {
            $script:ServicesFolder = New-RoleFolder "info-$([guid]::NewGuid().ToString('N'))/svc"
        }

        It 'is $null when the folder has no .env' {
            Get-ServicesStackInfo -ServicesFolder $script:ServicesFolder | Should -BeNullOrEmpty
        }

        It 'is $null when the .env is not a services stack (<Role>)' -ForEach @(
            @{ Role = '' }
            @{ Role = 'platform' }
        ) {
            Set-Content -LiteralPath (Join-Path $script:ServicesFolder '.env') -Value "STACK_ROLE=$Role`nCOMPOSE_FILE=docker-compose.yml"

            Get-ServicesStackInfo -ServicesFolder $script:ServicesFolder | Should -BeNullOrEmpty
        }

        It 'reads the project, the features, the two names the services start wrote and the table' {
            Set-Content -LiteralPath (Join-Path $script:ServicesFolder '.env') -Value @(
                'STACK_ROLE=services'
                'COMPOSE_PROJECT_NAME=svc'
                'COMPOSE_FILE=docker-compose.yml;docker-compose/postgres.yml;docker-compose/redis.yml'
                'SERVICES_NETWORK_NAME=svc-shared'
                'SERVICES_CERTS_VOLUME=svc_certs'
                'REDIS_PORT=6380'
            )

            $info = Get-ServicesStackInfo -ServicesFolder $script:ServicesFolder

            $info.Folder | Should -BeExactly $script:ServicesFolder
            $info.ProjectName | Should -BeExactly 'svc'
            $info.Features.Provider | Should -BeExactly 'postgres'
            $info.Features.Redis | Should -BeTrue
            $info.Features.Elasticsearch | Should -BeFalse
            $info.NetworkName | Should -BeExactly 'svc-shared'
            $info.CertsVolume | Should -BeExactly 'svc_certs'
            $info.EnvTable['REDIS_PORT'] | Should -BeExactly '6380'
        }

        It 'names the project after the folder when COMPOSE_PROJECT_NAME is empty' {
            Set-Content -LiteralPath (Join-Path $script:ServicesFolder '.env') -Value "STACK_ROLE=services`nCOMPOSE_PROJECT_NAME="

            (Get-ServicesStackInfo -ServicesFolder $script:ServicesFolder).ProjectName | Should -BeExactly 'svc'
        }

        It 'leaves the two names empty before the services start has written them (P17)' {
            Set-Content -LiteralPath (Join-Path $script:ServicesFolder '.env') -Value "STACK_ROLE=services"

            $info = Get-ServicesStackInfo -ServicesFolder $script:ServicesFolder

            $info.NetworkName | Should -BeExactly ''
            $info.CertsVolume | Should -BeExactly ''
        }
    }

    Context 'Get-StackEnvTable (P2)' {
        BeforeEach {
            $parent = "table-$([guid]::NewGuid().ToString('N'))"
            $script:ServicesFolder = New-RoleFolder "$parent/svc"
            $script:PlatformFolder = New-RoleFolder "$parent/platform"
            Set-Content -LiteralPath (Join-Path $script:ServicesFolder '.env') -Value @(
                'STACK_ROLE=services'
                'REDIS_PORT=6380'
                'PLATFORM_PORT=8090'
                'VOLUME_PREFIX=svc'
            )
        }

        It 'takes a key the platform .env lacks from the services .env' {
            $document = ConvertFrom-EnvText "STACK_ROLE=platform`nSERVICES_FOLDER=../svc`n"

            $table = Get-StackEnvTable -Document $document -SolutionFolder $script:PlatformFolder

            $table['REDIS_PORT'] | Should -BeExactly '6380'
        }

        It 'lets the platform value win over the services value' {
            $document = ConvertFrom-EnvText "STACK_ROLE=platform`nSERVICES_FOLDER=../svc`nPLATFORM_PORT=8091`n"

            (Get-StackEnvTable -Document $document -SolutionFolder $script:PlatformFolder)['PLATFORM_PORT'] | Should -BeExactly '8091'
        }

        It 'lets a key present but empty in the platform .env win over the services value' {
            $document = ConvertFrom-EnvText "STACK_ROLE=platform`nSERVICES_FOLDER=../svc`nVOLUME_PREFIX=`n"

            $table = Get-StackEnvTable -Document $document -SolutionFolder $script:PlatformFolder

            $table.Contains('VOLUME_PREFIX') | Should -BeTrue
            $table['VOLUME_PREFIX'] | Should -BeExactly ''
        }

        It 'is the platform table alone when SERVICES_FOLDER is empty' {
            $document = ConvertFrom-EnvText "STACK_ROLE=platform`nSERVICES_FOLDER=`nPLATFORM_PORT=8091`n"

            $table = Get-StackEnvTable -Document $document -SolutionFolder $script:PlatformFolder

            $table['PLATFORM_PORT'] | Should -BeExactly '8091'
            $table.Contains('REDIS_PORT') | Should -BeFalse
        }

        It 'is the platform table alone when the services folder is not a services stack' {
            $document = ConvertFrom-EnvText "STACK_ROLE=platform`nSERVICES_FOLDER=../missing`n"

            $table = Get-StackEnvTable -Document $document -SolutionFolder $script:PlatformFolder

            $table.Contains('REDIS_PORT') | Should -BeFalse
        }

        It 'is Get-EnvTable for a standalone and for a services .env' {
            $document = ConvertFrom-EnvText "STACK_ROLE=services`nSERVICES_FOLDER=../svc`nPLATFORM_PORT=8091`n"

            $table = Get-StackEnvTable -Document $document -SolutionFolder $script:PlatformFolder

            $table.Keys | Should -Be (Get-EnvTable -Document $document).Keys
            $table.Contains('REDIS_PORT') | Should -BeFalse
        }
    }

    Context 'Get-IsolationDefaults (P11)' {
        It 'derives the four keys from the project name' {
            $defaults = Get-IsolationDefaults -ProjectName 'tenant-2'

            $defaults['DB_NAME'] | Should -BeExactly 'VirtoCommerce_tenant_2'
            $defaults['SEARCH_SCOPE'] | Should -BeExactly 'tenant-2'
            $defaults['REDIS_CHANNEL'] | Should -BeExactly 'VirtoCommerceChannel-tenant-2'
            $defaults['PLATFORM_HOSTNAME'] | Should -BeExactly 'tenant-2.dev.internal'
        }

        It 'turns an underscore into a hyphen in the host name, a hyphen into an underscore in the database name' {
            $defaults = Get-IsolationDefaults -ProjectName 'my_tenant-2'

            $defaults['PLATFORM_HOSTNAME'] | Should -BeExactly 'my-tenant-2.dev.internal'
            $defaults['DB_NAME'] | Should -BeExactly 'VirtoCommerce_my_tenant_2'
        }
    }

    Context 'Update-EnvForRole: platform' {
        BeforeEach {
            $script:PlatformFolder = New-RoleFolder "role-$([guid]::NewGuid().ToString('N'))/tenant-2"
            $script:Template = Read-EnvFile $script:ExamplePath
            $script:Document = New-PlatformDocument
        }

        It 'leaves no services-owned key in the .env' {
            $null = Update-EnvForRole -Document $script:Document -SolutionFolder $script:PlatformFolder -Template $script:Template

            $table = Get-EnvTable -Document $script:Document
            foreach ($key in Get-ServicesOwnedKeys) {
                $table.Contains($key) | Should -BeFalse -Because "$key belongs to the services stack"
            }
        }

        It 'removes a services-owned key the user left in, and reports it' {
            Set-EnvValue -Document $script:Document -Key 'REDIS_PORT' -Value '6390'

            $changed = Update-EnvForRole -Document $script:Document -SolutionFolder $script:PlatformFolder -Template $script:Template

            $changed | Should -Contain 'REDIS_PORT'
            (Get-EnvTable -Document $script:Document).Contains('REDIS_PORT') | Should -BeFalse
        }

        It 'writes the project name and the isolation defaults' {
            $null = Update-EnvForRole -Document $script:Document -SolutionFolder $script:PlatformFolder -Template $script:Template

            $table = Get-EnvTable -Document $script:Document
            $table['COMPOSE_PROJECT_NAME'] | Should -BeExactly 'tenant-2'
            $table['DB_NAME'] | Should -BeExactly 'VirtoCommerce_tenant_2'
            $table['SEARCH_SCOPE'] | Should -BeExactly 'tenant-2'
            $table['REDIS_CHANNEL'] | Should -BeExactly 'VirtoCommerceChannel-tenant-2'
            $table['PLATFORM_HOSTNAME'] | Should -BeExactly 'tenant-2.dev.internal'
        }

        It 'does not touch REDIS_DATABASE (the registry gives it out)' {
            $null = Update-EnvForRole -Document $script:Document -SolutionFolder $script:PlatformFolder -Template $script:Template

            (Get-EnvTable -Document $script:Document)['REDIS_DATABASE'] | Should -BeExactly ''
        }

        It 'keeps the values the user set' {
            foreach ($pair in @{ COMPOSE_PROJECT_NAME = 'mine'; DB_NAME = 'Custom'; SEARCH_SCOPE = 'custom'; REDIS_CHANNEL = 'ch'; PLATFORM_HOSTNAME = 'custom.dev.internal'; PLATFORM_PORT = '8091'; BIND_ADDRESS = '0.0.0.0'; VOLUME_PREFIX = 'vp' }.GetEnumerator()) {
                Set-EnvValue -Document $script:Document -Key $pair.Key -Value $pair.Value
            }

            $null = Update-EnvForRole -Document $script:Document -SolutionFolder $script:PlatformFolder -Template $script:Template

            $table = Get-EnvTable -Document $script:Document
            $table['COMPOSE_PROJECT_NAME'] | Should -BeExactly 'mine'
            $table['DB_NAME'] | Should -BeExactly 'Custom'
            $table['SEARCH_SCOPE'] | Should -BeExactly 'custom'
            $table['REDIS_CHANNEL'] | Should -BeExactly 'ch'
            $table['PLATFORM_HOSTNAME'] | Should -BeExactly 'custom.dev.internal'
            $table['PLATFORM_PORT'] | Should -BeExactly '8091'
            $table['BIND_ADDRESS'] | Should -BeExactly '0.0.0.0'
            $table['VOLUME_PREFIX'] | Should -BeExactly 'vp'
        }

        It 'derives the isolation defaults from a COMPOSE_PROJECT_NAME the user set' {
            Set-EnvValue -Document $script:Document -Key 'COMPOSE_PROJECT_NAME' -Value 'other'

            $null = Update-EnvForRole -Document $script:Document -SolutionFolder $script:PlatformFolder -Template $script:Template

            (Get-EnvTable -Document $script:Document)['DB_NAME'] | Should -BeExactly 'VirtoCommerce_other'
        }

        It 'changes nothing on a second call' {
            $null = Update-EnvForRole -Document $script:Document -SolutionFolder $script:PlatformFolder -Template $script:Template
            $before = ConvertTo-EnvText $script:Document

            $second = Update-EnvForRole -Document $script:Document -SolutionFolder $script:PlatformFolder -Template $script:Template

            @($second).Count | Should -Be 0
            ConvertTo-EnvText $script:Document | Should -BeExactly $before
        }

        # Review Focus 1: Compose would give the platform stack's volumes the services prefix.
        It 'puts back a VOLUME_PREFIX the user deleted' {
            $null = Remove-EnvKey -Document $script:Document -Key 'VOLUME_PREFIX'

            $changed = Update-EnvForRole -Document $script:Document -SolutionFolder $script:PlatformFolder -Template $script:Template

            $changed | Should -Contain 'VOLUME_PREFIX'
            $table = Get-EnvTable -Document $script:Document
            $table.Contains('VOLUME_PREFIX') | Should -BeTrue
            $table['VOLUME_PREFIX'] | Should -BeExactly ''
        }

        It 'puts back PLATFORM_PORT next to where the template has it, not at the top of the file' {
            $null = Update-EnvForRole -Document $script:Document -SolutionFolder $script:PlatformFolder -Template $script:Template
            $null = Remove-EnvKey -Document $script:Document -Key 'PLATFORM_PORT'

            $null = Update-EnvForRole -Document $script:Document -SolutionFolder $script:PlatformFolder -Template $script:Template

            $keys = @($script:Document.Entries | Where-Object { $_.Kind -eq 'Pair' } | ForEach-Object { $_.Key })
            $keys[0] | Should -Not -BeExactly 'PLATFORM_PORT'
            $keys | Should -Contain 'PLATFORM_PORT'
            $keys[$keys.IndexOf('PLATFORM_PORT') + 1] | Should -BeExactly 'FRONTEND_PORT'
        }
    }

    Context 'Update-EnvForRole: services and standalone' {
        BeforeEach {
            $script:ServicesFolder = New-RoleFolder "role-$([guid]::NewGuid().ToString('N'))/svc"
            $script:Template = Read-EnvFile $script:ExamplePath
        }

        It 'writes COMPOSE_PROJECT_NAME for a services stack and leaves the two names empty (P17)' {
            $document = Read-EnvFile $script:ExamplePath
            Set-EnvValue -Document $document -Key 'STACK_ROLE' -Value 'services'

            $changed = Update-EnvForRole -Document $document -SolutionFolder $script:ServicesFolder -Template $script:Template

            $changed | Should -Be @('COMPOSE_PROJECT_NAME')
            $table = Get-EnvTable -Document $document
            $table['COMPOSE_PROJECT_NAME'] | Should -BeExactly 'svc'
            $table.Contains('SERVICES_NETWORK_NAME') | Should -BeFalse
            $table.Contains('SERVICES_CERTS_VOLUME') | Should -BeFalse
            $table['DB_PASSWORD'] | Should -BeExactly ''
        }

        It 'keeps the services stack its own keys' {
            $document = Read-EnvFile $script:ExamplePath
            Set-EnvValue -Document $document -Key 'STACK_ROLE' -Value 'services'

            $null = Update-EnvForRole -Document $document -SolutionFolder $script:ServicesFolder -Template $script:Template

            $table = Get-EnvTable -Document $document
            foreach ($key in 'REDIS_PORT', 'STACK_VERSION', 'PGSQL_PORT', 'REDIS_PASSWORD') {
                $table.Contains($key) | Should -BeTrue -Because "$key stays in the services .env"
            }
        }

        It 'keeps a COMPOSE_PROJECT_NAME the user set' {
            $document = ConvertFrom-EnvText "STACK_ROLE=services`nCOMPOSE_PROJECT_NAME=mine`n"

            $changed = Update-EnvForRole -Document $document -SolutionFolder $script:ServicesFolder -Template $script:Template

            @($changed).Count | Should -Be 0
            (Get-EnvTable -Document $document)['COMPOSE_PROJECT_NAME'] | Should -BeExactly 'mine'
        }

        It 'changes nothing in a standalone .env' {
            $document = Read-EnvFile $script:ExamplePath
            $before = ConvertTo-EnvText $document

            $changed = Update-EnvForRole -Document $document -SolutionFolder $script:ServicesFolder -Template $script:Template

            @($changed).Count | Should -Be 0
            ConvertTo-EnvText $document | Should -BeExactly $before
        }

        It 'throws naming STACK_ROLE for a role it does not know' {
            $document = ConvertFrom-EnvText "STACK_ROLE=Platform`n"

            { Update-EnvForRole -Document $document -SolutionFolder $script:ServicesFolder -Template $script:Template } |
                Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*STACK_ROLE*'
        }
    }

    Context 'Set-ServicesStackKeys (P5, P17)' {
        It 'writes the network and the certificates volume names of the services project' {
            $folder = New-RoleFolder "keys-$([guid]::NewGuid().ToString('N'))/svc"
            $document = Read-EnvFile $script:ExamplePath
            Set-EnvValue -Document $document -Key 'STACK_ROLE' -Value 'services'
            $null = Update-EnvForRole -Document $document -SolutionFolder $folder -Template (Read-EnvFile $script:ExamplePath)

            $changed = Set-ServicesStackKeys -Document $document -SolutionFolder $folder

            $changed | Should -Be @('SERVICES_NETWORK_NAME', 'SERVICES_CERTS_VOLUME')
            $table = Get-EnvTable -Document $document
            $table['SERVICES_NETWORK_NAME'] | Should -BeExactly 'svc-shared'
            $table['SERVICES_CERTS_VOLUME'] | Should -BeExactly 'svc_certs'
        }

        It 'follows VOLUME_PREFIX for the certificates volume and reports nothing on a second call' {
            $folder = New-RoleFolder "keys-$([guid]::NewGuid().ToString('N'))/svc"
            $document = ConvertFrom-EnvText "STACK_ROLE=services`nCOMPOSE_PROJECT_NAME=svc`nVOLUME_PREFIX=pfx`n"

            $null = Set-ServicesStackKeys -Document $document -SolutionFolder $folder
            $second = Set-ServicesStackKeys -Document $document -SolutionFolder $folder

            (Get-EnvTable -Document $document)['SERVICES_CERTS_VOLUME'] | Should -BeExactly 'pfx_certs'
            @($second).Count | Should -Be 0
        }
    }
}
