BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:FixtureFolder = Join-Path $PSScriptRoot '../fixtures/env'
    $script:Template = Read-EnvFile -Path (Join-Path $PSScriptRoot '../../.env.example')

    function script:Read-Fixture {
        param([string]$Name)
        Read-EnvFile -Path (Join-Path $script:FixtureFolder "$Name.env")
    }

    # A solution folder named VirtoLocal holding a copy of a layout 1 fixture as its .env.
    function script:New-LayoutOneFolder {
        param([string]$Fixture = 'layout1-postgres')
        $folder = Join-Path $TestDrive 'VirtoLocal'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Copy-Item -Path (Join-Path $script:FixtureFolder "$Fixture.env") -Destination (Join-Path $folder '.env') -Force
        $folder
    }
}

Describe 'Migrate' -Tag 'Unit' {
    Context 'Get-EnvLayout' {
        It 'treats a missing START_LOCAL_LAYOUT as layout 1' {
            Get-EnvLayout -Document (Read-Fixture 'layout1-postgres') | Should -Be 1
        }

        It 'reads START_LOCAL_LAYOUT' {
            Get-EnvLayout -Document $script:Template | Should -Be 2
        }

        # R35: a .env written beforehand (a cloud wrapper) has COMPOSE_FILE and no DB_PROVIDER; a layout-1 file has DB_PROVIDER.
        It 'treats an unmarked file with COMPOSE_FILE and no DB_PROVIDER as layout 2' {
            Get-EnvLayout -Document (ConvertFrom-EnvText "COMPOSE_FILE=docker-compose.yml;docker-compose/postgres.yml`n") | Should -Be 2
        }

        It 'treats an unmarked file with DB_PROVIDER as layout 1, even with a hand-added COMPOSE_FILE' {
            $document = Read-Fixture 'layout1-postgres'
            Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value 'docker-compose.yml;docker-compose.postgres.yml'
            Get-EnvLayout -Document $document | Should -Be 1
        }

        It 'fails on a value that is not a number' {
            $document = Read-Fixture 'layout1-postgres'
            Set-EnvValue -Document $document -Key 'START_LOCAL_LAYOUT' -Value 'two'
            { Get-EnvLayout -Document $document } | Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*START_LOCAL_LAYOUT*'
        }
    }

    Context 'Convert-EnvToLayout2' {
        It 'keeps Elasticsearch at 8.18.0, the layout-1 default, when STACK_VERSION is missing' {
            $document = Read-Fixture 'layout1-postgres'
            Remove-EnvKey -Document $document -Key 'STACK_VERSION'

            $null = Convert-EnvToLayout2 -Document $document -Template $script:Template

            Get-EnvValue -Document $document -Key 'STACK_VERSION' | Should -Be '8.18.0'
        }

        It 'maps DB_PROVIDER to COMPOSE_FILE in HTTP mode (<provider>)' -ForEach @(
            @{ Provider = 'postgres' }, @{ Provider = 'mysql' }, @{ Provider = 'sqlserver' }
        ) {
            $document = Read-Fixture "layout1-$Provider"
            $null = Convert-EnvToLayout2 -Document $document -Template $script:Template

            $expected = ConvertTo-ComposeFileValue (Get-DefaultComposeFiles $Provider -Https $false)
            Get-EnvValue -Document $document -Key 'COMPOSE_FILE' | Should -BeExactly $expected
            $expected | Should -Not -Match 'https'
        }

        It 'keeps every existing value' {
            $document = Read-Fixture 'layout1-edited-crlf'
            $null = Convert-EnvToLayout2 -Document $document -Template $script:Template

            Get-EnvValue -Document $document -Key 'DB_PASSWORD' | Should -BeExactly 'pgPass1'
            Get-EnvValue -Document $document -Key 'REDIS_PASSWORD' | Should -BeExactly 'redisPass1'
            Get-EnvValue -Document $document -Key 'ELASTIC_PASSWORD' | Should -BeExactly 'elasticPass1'
            Get-EnvValue -Document $document -Key 'KIBANA_PASSWORD' | Should -BeExactly 'kibanaPass1'
            Get-EnvValue -Document $document -Key 'PLATFORM_PORT' | Should -BeExactly '8091'
            Get-EnvValue -Document $document -Key 'FRONTEND_PORT' | Should -BeExactly '80'
            Get-EnvValue -Document $document -Key 'STACK_VERSION' | Should -BeExactly '8.18.0'
        }

        It 'adds keys' {
            $document = Read-Fixture 'layout1-postgres'
            $null = Convert-EnvToLayout2 -Document $document -Template $script:Template

            Get-EnvValue -Document $document -Key 'VOLUME_PREFIX' | Should -BeExactly 'virto'
            Get-EnvValue -Document $document -Key 'BIND_ADDRESS' | Should -BeExactly '127.0.0.1'
            Get-EnvValue -Document $document -Key 'SEARCH_PROVIDER' | Should -BeExactly 'ElasticSearch8'
            Get-EnvValue -Document $document -Key 'COMPOSE_PATH_SEPARATOR' | Should -BeExactly ';'
            Get-EnvValue -Document $document -Key 'START_LOCAL_LAYOUT' | Should -BeExactly '2'
        }

        It 'removes keys' {
            $document = Read-Fixture 'layout1-postgres'
            $null = Convert-EnvToLayout2 -Document $document -Template $script:Template

            $table = Get-EnvTable -Document $document
            $table.Contains('DB_PROVIDER') | Should -BeFalse
            $table.Contains('ES_CLUSTER_NAME') | Should -BeFalse
            $table.Contains('ES_LICENSE') | Should -BeFalse
        }

        It 'reports what it changed' {
            $document = Read-Fixture 'layout1-postgres'
            $result = Convert-EnvToLayout2 -Document $document -Template $script:Template

            $result.Document | Should -Be $document
            $result.Changes | Should -Contain 'Removed DB_PROVIDER'
            $result.Changes | Should -Contain 'Removed ES_CLUSTER_NAME'
            $result.Changes | Should -Contain 'Removed ES_LICENSE'
            $result.Changes | Where-Object { $_ -like 'Set COMPOSE_FILE=*' } | Should -Not -BeNullOrEmpty
            $result.Changes | Should -Contain 'Added BIND_ADDRESS'
        }

        It 'is idempotent' {
            $document = Read-Fixture 'layout1-postgres'
            $null = Convert-EnvToLayout2 -Document $document -Template $script:Template
            $text = ConvertTo-EnvText -Document $document

            $second = Convert-EnvToLayout2 -Document $document -Template $script:Template

            $second.Changes | Should -BeNullOrEmpty
            $second.Notes | Should -BeNullOrEmpty
            ConvertTo-EnvText -Document $document | Should -BeExactly $text
        }

        It 'leaves a document that already has layout 2 alone' {
            $document = [pscustomobject]@{ Eol = "`n"; Bom = $false; Entries = [System.Collections.Generic.List[object]]::new() }
            foreach ($entry in $script:Template.Entries) { $document.Entries.Add($entry.Clone()) }
            $text = ConvertTo-EnvText -Document $document

            $result = Convert-EnvToLayout2 -Document $document -Template $script:Template

            $result.Changes | Should -BeNullOrEmpty
            ConvertTo-EnvText -Document $document | Should -BeExactly $text
        }

        It 'keeps CRLF' {
            $document = Read-Fixture 'layout1-edited-crlf'
            $null = Convert-EnvToLayout2 -Document $document -Template $script:Template

            $document.Eol | Should -BeExactly "`r`n"
            (ConvertTo-EnvText -Document $document) | Should -Match "`r`n"
            (ConvertTo-EnvText -Document $document) -replace "`r`n", '' | Should -Not -Match "[`r`n]"
        }

        It 'Notes explain the bind change' {
            $result = Convert-EnvToLayout2 -Document (Read-Fixture 'layout1-postgres') -Template $script:Template

            ($result.Notes -join "`n") | Should -Match 'BIND_ADDRESS=0\.0\.0\.0'
        }

        It 'fails on a missing or bad provider (<fixture>)' -ForEach @(
            @{ Fixture = 'layout1-no-provider' }, @{ Fixture = 'layout1-bad-provider' }
        ) {
            $document = Read-Fixture $Fixture
            $before = ConvertTo-EnvText -Document $document

            { Convert-EnvToLayout2 -Document $document -Template $script:Template } |
                Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*DB_PROVIDER*'
            ConvertTo-EnvText -Document $document | Should -BeExactly $before
        }
    }

    Context 'Invoke-StartLocalMigration' {
        BeforeEach {
            # Old images cannot run under the layout-2 compose files, so the migration rebuilds instead of retagging:
            # it must not call Docker at all.
            function script:docker { throw 'the migration called docker' }
        }

        AfterEach {
            Remove-Item -LiteralPath function:script:docker -ErrorAction Ignore
        }

        It 'writes the migrated .env without Docker, and a second run changes nothing' {
            $folder = New-LayoutOneFolder
            $envPath = Join-Path $folder '.env'

            $first = Invoke-StartLocalMigration -SolutionFolder $folder 6>$null
            $migrated = Get-Content -Raw -Path $envPath
            $second = Invoke-StartLocalMigration -SolutionFolder $folder 6>$null

            $first.Changes | Should -Not -BeNullOrEmpty
            $migrated | Should -Match '(?m)^START_LOCAL_LAYOUT=2$'
            $migrated | Should -Not -Match '(?m)^DB_PROVIDER='
            $second.Changes | Should -BeNullOrEmpty
            (Get-Content -Raw -Path $envPath) | Should -BeExactly $migrated
        }

        It 'prints the changes and the notes' {
            $folder = New-LayoutOneFolder

            $printed = Invoke-StartLocalMigration -SolutionFolder $folder 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }

            ($printed -join "`n") | Should -Match 'Removed DB_PROVIDER'
            ($printed -join "`n") | Should -Match 'BIND_ADDRESS=0\.0\.0\.0'
        }

        It 'leaves .env untouched when the provider is bad' {
            $folder = New-LayoutOneFolder -Fixture 'layout1-bad-provider'
            $before = Get-Content -Raw -Path (Join-Path $folder '.env')

            { Invoke-StartLocalMigration -SolutionFolder $folder 6>$null } | Should -Throw -ExpectedMessage '*DB_PROVIDER*'

            (Get-Content -Raw -Path (Join-Path $folder '.env')) | Should -BeExactly $before
        }

        It 'on a folder without .env returns $null' {
            $folder = Join-Path $TestDrive 'empty'
            $null = New-Item -ItemType Directory -Path $folder

            Invoke-StartLocalMigration -SolutionFolder $folder 6>$null | Should -BeNullOrEmpty
        }
    }
}
