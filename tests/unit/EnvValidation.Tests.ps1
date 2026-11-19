BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:PostgresFiles = [string[]](Get-DefaultComposeFiles -Provider postgres)
    $script:SqlServerFiles = [string[]](Get-DefaultComposeFiles -Provider sqlserver)

    # Values of a valid .env for the checks below; extra values override.
    function script:New-ValidEnv {
        param([hashtable]$Values = @{})

        $table = [ordered]@{ DB_PASSWORD = 'Abcdefg1'; REDIS_PASSWORD = 'r1'; ELASTIC_PASSWORD = 'e1'; KIBANA_PASSWORD = 'k1'; ADMIN_PASSWORD = '' }
        foreach ($port in @{ PGSQL_PORT = '5432'; MSSQL_PORT = '1433'; PLATFORM_PORT = '8090'; ES_PORT = '9200'; KIBANA_PORT = '5601'; FRONTEND_PORT = '443' }.GetEnumerator()) {
            $table[$port.Key] = $port.Value
        }
        foreach ($key in $Values.Keys) { $table[$key] = $Values[$key] }
        $table
    }
}

Describe '.env validation' -Tag 'Unit' {
    Context 'reading and writing the file' {
        It 'stops with the file name when .env is not valid UTF-8' {
            $path = Join-Path $TestDrive 'bad-utf8.env'
            [System.IO.File]::WriteAllBytes($path, [byte[]](0x41, 0x3D, 0xFF, 0xFE, 0x0A))

            { Read-EnvFile -Path $path } | Should -Throw -ExceptionType ([System.FormatException]) -ExpectedMessage "*$path*UTF-8*"
        }

        It 'stops with the line and key for a value whose quote is not closed' {
            { ConvertFrom-EnvText "A=1`nDB_PASSWORD=`"abc`nB=2" } |
                Should -Throw -ExceptionType ([System.FormatException]) -ExpectedMessage '*line 2*DB_PASSWORD*'
        }

        It 'saves through a temporary file and leaves none behind' {
            $path = Join-Path $TestDrive 'saved.env'
            Write-EnvFile -Document (ConvertFrom-EnvText "A=1`n") -Path $path

            Get-Content -LiteralPath $path -Raw | Should -BeExactly "A=1`n"
            Get-ChildItem -LiteralPath $TestDrive -Filter 'saved.env*' | ForEach-Object { $_.Name } | Should -Be @('saved.env')
        }
    }

    Context 'Get-ComposeSeparator' {
        It 'is "<Expected>" for COMPOSE_PATH_SEPARATOR "<Text>"' -ForEach @(
            @{ Text = "A=1`n"; Expected = ';' }
            @{ Text = "COMPOSE_PATH_SEPARATOR=`n"; Expected = ';' }
            @{ Text = "COMPOSE_PATH_SEPARATOR=:`n"; Expected = ':' }
        ) {
            Get-ComposeSeparator -Document (ConvertFrom-EnvText $Text) | Should -BeExactly $Expected
        }
    }

    Context 'Get-ComposeFileList' {
        It 'reads a leading ./ as the same file' {
            $files = Get-ComposeFileList './docker-compose.yml;./docker-compose/postgres.yml'
            $files | Should -Be @('docker-compose.yml', 'docker-compose/postgres.yml')
        }
    }

    Context 'Test-EnvValues' {
        It 'accepts a valid .env' {
            Test-EnvValues -EnvValues (New-ValidEnv) -ComposeFiles $script:PostgresFiles | Should -BeNullOrEmpty
        }

        It 'rejects a $ in <Key>: the scripts read it as typed, Compose replaces $name with a variable' -ForEach @(
            @{ Key = 'DB_PASSWORD' }
            @{ Key = 'ADMIN_PASSWORD' }
        ) {
            $errors = Test-EnvValues -EnvValues (New-ValidEnv @{ $Key = 'Abc$def1' }) -ComposeFiles $script:PostgresFiles

            ($errors -join "`n") | Should -Match $Key
            ($errors -join "`n") | Should -Match '\$'
        }

        It 'rejects ADMIN_PASSWORD "<Password>": the platform needs 8+ characters with an uppercase and a lowercase letter' -ForEach @(
            @{ Password = 'Short1' }
            @{ Password = 'alllowercase1' }
            @{ Password = 'ALLUPPERCASE1' }
        ) {
            $errors = Test-EnvValues -EnvValues (New-ValidEnv @{ ADMIN_PASSWORD = $Password }) -ComposeFiles $script:PostgresFiles

            ($errors -join "`n") | Should -Match 'ADMIN_PASSWORD'
        }

        It 'accepts an ADMIN_PASSWORD with both cases and 8+ characters, and an empty one (it is generated)' -ForEach @(
            @{ Password = 'NoDigitsHere' }
            @{ Password = '' }
        ) {
            Test-EnvValues -EnvValues (New-ValidEnv @{ ADMIN_PASSWORD = $Password }) -ComposeFiles $script:PostgresFiles | Should -BeNullOrEmpty
        }

        It 'rejects a SQL Server DB_PASSWORD "<Password>" (8+ characters from 3 of: upper, lower, digit, symbol)' -ForEach @(
            @{ Password = 'abcdefgh' }
            @{ Password = 'Abc1' }
        ) {
            $errors = Test-EnvValues -EnvValues (New-ValidEnv @{ DB_PASSWORD = $Password }) -ComposeFiles $script:SqlServerFiles

            ($errors -join "`n") | Should -Match 'DB_PASSWORD'
            ($errors -join "`n") | Should -Match 'SQL Server'
        }

        It 'applies the SQL Server rule only to SQL Server' {
            Test-EnvValues -EnvValues (New-ValidEnv @{ DB_PASSWORD = 'abcdefgh' }) -ComposeFiles $script:PostgresFiles | Should -BeNullOrEmpty
        }

        It 'reports a COMPOSE_FILE with no database' {
            $files = [string[]]@($script:PostgresFiles | Where-Object { $_ -notlike '*postgres*' })

            (Test-EnvValues -EnvValues (New-ValidEnv) -ComposeFiles $files) -join "`n" | Should -Match 'database'
        }

        It 'reports a COMPOSE_FILE with two databases' {
            $files = [string[]]@($script:PostgresFiles + 'docker-compose/mysql.yml')

            (Test-EnvValues -EnvValues (New-ValidEnv) -ComposeFiles $files) -join "`n" | Should -Match 'more than one database'
        }

        It 'names the new file for an old flat name such as docker-compose.kibana.yml' {
            $files = [string[]]@($script:PostgresFiles + 'docker-compose.kibana.yml')

            (Test-EnvValues -EnvValues (New-ValidEnv) -ComposeFiles $files) -join "`n" | Should -Match 'docker-compose/kibana\.yml'
        }
    }

    Context 'empty port keys' {
        It 'reports an empty <Key>: Compose would publish a random port' -ForEach @(
            @{ Key = 'PLATFORM_PORT' }
            @{ Key = 'PGSQL_PORT' }
        ) {
            $values = New-ValidEnv @{ $Key = '' }

            { Get-RequiredPorts -EnvValues $values -ComposeFiles $script:PostgresFiles } |
                Should -Throw -ExceptionType ([System.FormatException]) -ExpectedMessage "*$Key is empty*"
        }
    }
}

Describe 'Port catalog' -Tag 'Unit' {
    It 'lists the storefront on <Expected> when FRONTEND_PORT is left out (HTTPS <Https>)' -ForEach @(
        @{ Https = $true; Expected = 'https://localhost:443' }
        @{ Https = $false; Expected = 'http://localhost:80' }
    ) {
        $urls = Get-ServiceUrls -EnvValues @{} -ComposeFiles ([string[]](Get-DefaultComposeFiles -Provider postgres -Https $Https))

        ($urls | Where-Object { $_.Name -eq 'Storefront' }).Url | Should -Be $Expected
    }

    It 'is the one place that knows each port: its key, standard port and container port' {
        foreach ($entry in $script:PortCatalog) {
            $entry.Key | Should -Match '_PORT$'
            $entry.Default | Should -BeOfType [int]
            $entry.ContainerPort | Should -BeOfType [int]
        }
        (Get-PortEntry -Key 'MSSQL_PORT').ContainerPort | Should -Be 1433
    }
}
