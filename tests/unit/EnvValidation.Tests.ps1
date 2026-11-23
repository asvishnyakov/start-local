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

        It 'replaces the file in one rename, so a reader never sees it cut short' -Skip:$IsWindows {
            $path = Join-Path $TestDrive 'renamed.env'
            Set-Content -LiteralPath $path -Value 'A=0' -NoNewline
            $inodeBefore = (Get-Item -LiteralPath $path).UnixStat.Inode

            Write-EnvFile -Document (ConvertFrom-EnvText "A=1`n") -Path $path

            Get-Content -LiteralPath $path -Raw | Should -BeExactly "A=1`n"
            # A new inode: the content was written elsewhere and renamed over the old file.
            (Get-Item -LiteralPath $path).UnixStat.Inode | Should -Not -Be $inodeBefore
        }

        It 'keeps the permissions of the existing file' -Skip:$IsWindows {
            $path = Join-Path $TestDrive 'private.env'
            Set-Content -LiteralPath $path -Value 'A=0' -NoNewline
            & chmod 600 $path
            Assert-NativeSuccess 'chmod 600'

            Write-EnvFile -Document (ConvertFrom-EnvText "A=1`n") -Path $path

            (Get-Item -LiteralPath $path).UnixMode | Should -BeExactly '-rw-------'
        }

        It 'keeps a mode that the umask would narrow when the new file is created' -Skip:$IsWindows {
            $path = Join-Path $TestDrive 'shared.env'
            Set-Content -LiteralPath $path -Value 'A=0' -NoNewline
            & chmod 666 $path
            Assert-NativeSuccess 'chmod 666'

            Write-EnvFile -Document (ConvertFrom-EnvText "A=1`n") -Path $path

            (Get-Item -LiteralPath $path).UnixMode | Should -BeExactly '-rw-rw-rw-'
        }

        It 'creates the temporary file with the mode of the existing file, and with the default mode for a new .env' -Skip:$IsWindows {
            # Not $path: inside the mock and its filter that is New-FileForWrite's own parameter.
            $envPath = Join-Path $TestDrive 'created.env'
            Mock New-FileForWrite { [System.IO.FileStream]::new($Path, [System.IO.FileMode]::CreateNew) }

            Write-EnvFile -Document (ConvertFrom-EnvText "A=1`n") -Path $envPath
            Should -Invoke New-FileForWrite -Times 1 -Exactly -ParameterFilter { $null -eq $UnixMode -and $Path -ceq "$envPath.tmp" }

            & chmod 600 $envPath
            Assert-NativeSuccess 'chmod 600'
            Write-EnvFile -Document (ConvertFrom-EnvText "A=2`n") -Path $envPath
            Should -Invoke New-FileForWrite -Times 1 -Exactly -ParameterFilter { $UnixMode -eq [System.IO.UnixFileMode]'UserRead, UserWrite' }
        }

        It 'New-FileForWrite gives the file its mode from the moment it exists, so the secrets are never in a more readable file' -Skip:$IsWindows {
            $path = Join-Path $TestDrive 'private.tmp'

            $stream = New-FileForWrite -Path $path -UnixMode ([System.IO.UnixFileMode]'UserRead, UserWrite')
            try {
                # Still open and empty: nothing but the creation has set the mode.
                (Get-Item -LiteralPath $path).UnixMode | Should -BeExactly '-rw-------'
            }
            finally {
                $stream.Dispose()
            }
        }

        It 'New-FileForWrite refuses a file that is already there: it would keep its own mode' {
            $path = Join-Path $TestDrive 'taken.tmp'
            Set-Content -LiteralPath $path -Value 'old'

            { New-FileForWrite -Path $path } | Should -Throw
        }

        It 'replaces a temporary file that a killed run left behind, rather than writing into it' -Skip:$IsWindows {
            $path = Join-Path $TestDrive 'resumed.env'
            Set-Content -LiteralPath $path -Value 'A=0' -NoNewline
            & chmod 600 $path
            Assert-NativeSuccess 'chmod 600'
            # World-readable, as an older version left it: reused, it would hold the secrets in that mode.
            Set-Content -LiteralPath "$path.tmp" -Value 'stale'
            & chmod 644 "$path.tmp"
            Assert-NativeSuccess 'chmod 644'

            Write-EnvFile -Document (ConvertFrom-EnvText "A=1`n") -Path $path

            Get-Content -LiteralPath $path -Raw | Should -BeExactly "A=1`n"
            (Get-Item -LiteralPath $path).UnixMode | Should -BeExactly '-rw-------'
            "$path.tmp" | Should -Not -Exist
        }

        It 'writes through a symlinked .env to its target and keeps the link and the target''s mode (<Label>)' -Skip:$IsWindows -ForEach @(
            @{ Label = 'an absolute link'; Relative = $false }
            # What dotfile managers create.
            @{ Label = 'a relative link'; Relative = $true }
        ) {
            $folder = Join-Path $TestDrive "linked-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path (Join-Path $folder 'store') -Force
            $target = Join-Path $folder 'store/real.env'
            $link = Join-Path $folder '.env'
            Set-Content -LiteralPath $target -Value 'A=0' -NoNewline
            & chmod 600 $target
            Assert-NativeSuccess 'chmod 600'
            $null = New-Item -ItemType SymbolicLink -Path $link -Target $(if ($Relative) { 'store/real.env' } else { $target })

            Write-EnvFile -Document (ConvertFrom-EnvText "A=1`n") -Path $link

            # -Force: off Windows a name that starts with a dot is hidden.
            (Get-Item -LiteralPath $link -Force).LinkType | Should -Be 'SymbolicLink'
            Get-Content -LiteralPath $target -Raw | Should -BeExactly "A=1`n"
            (Get-Item -LiteralPath $target).UnixMode | Should -BeExactly '-rw-------'
            # The temporary file was next to the target, and is gone.
            @(Get-ChildItem -LiteralPath $folder -Recurse -Force -Filter '*.tmp') | Should -BeNullOrEmpty
        }

        It 'creates the target of a symlinked .env that points at no file yet' -Skip:$IsWindows {
            $folder = Join-Path $TestDrive "dangling-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $folder -Force
            $target = Join-Path $folder 'real.env'
            $link = Join-Path $folder '.env'
            $null = New-Item -ItemType SymbolicLink -Path $link -Target $target

            Write-EnvFile -Document (ConvertFrom-EnvText "A=1`n") -Path $link

            (Get-Item -LiteralPath $link -Force).LinkType | Should -Be 'SymbolicLink'
            Get-Content -LiteralPath $target -Raw | Should -BeExactly "A=1`n"
        }

        It 'leaves no temporary file behind when the rename fails' {
            # A folder where the file should be: the rename over it fails.
            $path = Join-Path $TestDrive 'blocked.env'
            $null = New-Item -ItemType Directory -Path $path

            { Write-EnvFile -Document (ConvertFrom-EnvText "A=1`n") -Path $path } | Should -Throw

            Join-Path $TestDrive 'blocked.env.tmp' | Should -Not -Exist
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

        # The check asks the document which values reference a variable (Get-EnvVariableKeys): expansion has already
        # replaced it in $EnvValues, and a single-quoted value is not expanded at all.
        It 'rejects a $name in <Key>: Compose and the scripts expand it, so the password is not the text in .env' -ForEach @(
            @{ Key = 'DB_PASSWORD' }
            @{ Key = 'REDIS_PASSWORD' }
            @{ Key = 'ELASTIC_PASSWORD' }
            @{ Key = 'KIBANA_PASSWORD' }
        ) {
            $errors = Test-EnvValues -EnvValues (New-ValidEnv @{ $Key = 'Abc' }) -KeysWithVariables $Key -ComposeFiles $script:PostgresFiles

            ($errors -join "`n") | Should -Match $Key
            ($errors -join "`n") | Should -Match 'expand'
        }

        It 'reads <Line> as <Verdict>: only an expanded $name counts, $$ and single quotes are literal' -ForEach @(
            @{ Line = 'DB_PASSWORD=Ab$cd1'; Verdict = 'a variable'; Rejected = $true }
            @{ Line = 'DB_PASSWORD="Ab${X}1"'; Verdict = 'a variable'; Rejected = $true }
            @{ Line = 'DB_PASSWORD=Ab$$cd1'; Verdict = 'literal'; Rejected = $false }
            @{ Line = "DB_PASSWORD='Ab`$cd1'"; Verdict = 'literal'; Rejected = $false }
            # A '$' that no name or '{' follows stays as written in Compose 5.7.0.
            @{ Line = 'DB_PASSWORD=pa$'; Verdict = 'literal'; Rejected = $false }
            @{ Line = 'DB_PASSWORD=a$1b'; Verdict = 'literal'; Rejected = $false }
            @{ Line = 'DB_PASSWORD="Ab$ cd"'; Verdict = 'literal'; Rejected = $false }
        ) {
            $document = ConvertFrom-EnvText $Line
            (Get-EnvVariableKeys -Document $document) -contains 'DB_PASSWORD' | Should -Be $Rejected
        }

        It 'rejects a $name in ADMIN_PASSWORD for its real effect: Compose warns about a variable on every run' {
            $errors = Test-EnvValues -EnvValues (New-ValidEnv @{ ADMIN_PASSWORD = 'Abc' }) -KeysWithVariables 'ADMIN_PASSWORD' -ComposeFiles $script:PostgresFiles

            ($errors -join "`n") | Should -Match 'ADMIN_PASSWORD'
            ($errors -join "`n") | Should -Match 'warn'
        }

        # The connection strings, the Redis options and es-setup's JSON each break on some of these, and Compose can
        # quote none of them; generated passwords are letters and digits.
        It 'rejects <Label> in <Key>' -ForEach @(
            foreach ($key in 'DB_PASSWORD', 'REDIS_PASSWORD', 'ELASTIC_PASSWORD', 'KIBANA_PASSWORD') {
                @{ Key = $key; Label = 'a semicolon'; Value = 'Ab;cd1' }
                @{ Key = $key; Label = 'a comma'; Value = 'Ab,cd1' }
                @{ Key = $key; Label = 'a single quote'; Value = "Ab'cd1" }
                @{ Key = $key; Label = 'a double quote'; Value = 'Ab"cd1' }
                @{ Key = $key; Label = 'a backslash'; Value = 'Ab\cd1' }
                @{ Key = $key; Label = 'a leading space'; Value = ' Abcd1' }
                @{ Key = $key; Label = 'a trailing space'; Value = 'Abcd1 ' }
                @{ Key = $key; Label = 'a control character'; Value = "Ab`tcd1" }
                # The drivers read "Password==x" as part of the keyword.
                @{ Key = $key; Label = 'a leading equals sign'; Value = '=Abcd1' }
            }
        ) {
            $errors = Test-EnvValues -EnvValues (New-ValidEnv @{ $Key = $Value }) -ComposeFiles $script:PostgresFiles

            ($errors -join "`n") | Should -Match $Key
            ($errors -join "`n") | Should -Match 'cannot contain'
        }

        # From the .env line, as start.ps1 reads it: quotes that are .env syntax are not part of the password.
        It 'reads the .env line <Line> as <Verdict>' -ForEach @(
            @{ Line = 'DB_PASSWORD="Abcdef12"'; Verdict = 'accepted'; Rejected = $false }
            @{ Line = "DB_PASSWORD='Abcdef12'"; Verdict = 'accepted'; Rejected = $false }
            @{ Line = 'DB_PASSWORD=   Abcdef12   '; Verdict = 'accepted (Compose trims it)'; Rejected = $false }
            @{ Line = 'DB_PASSWORD=" Abcdef12"'; Verdict = 'rejected (the quotes keep the space)'; Rejected = $true }
            @{ Line = 'DB_PASSWORD="Ab\"cdef12"'; Verdict = 'rejected (an escaped quote)'; Rejected = $true }
            @{ Line = 'DB_PASSWORD="Ab\tcdef12"'; Verdict = 'rejected (an escaped tab)'; Rejected = $true }
            @{ Line = 'DB_PASSWORD==Abcdef12'; Verdict = 'rejected (a leading equals sign)'; Rejected = $true }
            @{ Line = 'DB_PASSWORD=Ab=cdef12'; Verdict = 'accepted (an inner equals sign)'; Rejected = $false }
        ) {
            $document = ConvertFrom-EnvText $Line
            $values = New-ValidEnv
            $values['DB_PASSWORD'] = (Get-EnvTable -Document $document)['DB_PASSWORD']

            $errors = Test-EnvValues -EnvValues $values -KeysWithVariables (Get-EnvVariableKeys -Document $document) -ComposeFiles $script:PostgresFiles

            [bool]@($errors | Where-Object { $_ -like 'DB_PASSWORD*cannot contain*' }).Count | Should -Be $Rejected
        }

        It 'accepts the other printable characters and an inner space in <Key>' -ForEach @(
            @{ Key = 'DB_PASSWORD' }, @{ Key = 'REDIS_PASSWORD' }, @{ Key = 'ELASTIC_PASSWORD' }, @{ Key = 'KIBANA_PASSWORD' }
        ) {
            Test-EnvValues -EnvValues (New-ValidEnv @{ $Key = 'Ab cd-_.!@#%^&*()+=[]{}:/?~<>|`1' }) -ComposeFiles $script:PostgresFiles | Should -BeNullOrEmpty
        }

        It 'rejects ADMIN_PASSWORD "<Password>" in a non-interactive run: the platform needs 8+ characters with an uppercase and a lowercase letter' -ForEach @(
            @{ Password = 'Short1' }
            @{ Password = 'Abcdefg' }
            @{ Password = 'alllowercase1' }
            @{ Password = 'ALLUPPERCASE1' }
        ) {
            $errors = Test-EnvValues -EnvValues (New-ValidEnv @{ ADMIN_PASSWORD = $Password }) -ComposeFiles $script:PostgresFiles -NonInteractive $true

            ($errors -join "`n") | Should -Match 'ADMIN_PASSWORD'
        }

        It 'accepts an ADMIN_PASSWORD "<Password>" with both cases and 8+ characters, and an empty one (it is generated)' -ForEach @(
            @{ Password = 'NoDigitsHere' }
            @{ Password = 'Abcdefgh' }
            @{ Password = '' }
        ) {
            Test-EnvValues -EnvValues (New-ValidEnv @{ ADMIN_PASSWORD = $Password }) -ComposeFiles $script:PostgresFiles -NonInteractive $true | Should -BeNullOrEmpty
        }

        It 'leaves a short ADMIN_PASSWORD alone in an interactive run, which only tries it as a sign-in candidate' {
            Test-EnvValues -EnvValues (New-ValidEnv @{ ADMIN_PASSWORD = 'store' }) -ComposeFiles $script:PostgresFiles -NonInteractive $false | Should -BeNullOrEmpty
        }

        It 'rejects a SQL Server DB_PASSWORD "<Password>" (8+ characters from 3 of: upper, lower, digit, symbol)' -ForEach @(
            @{ Password = 'abcdefgh' }
            @{ Password = 'Abc1' }
            @{ Password = 'Abcdefgh' }
            @{ Password = 'abcdefg1' }
            @{ Password = 'Abcdef1' }
        ) {
            $errors = Test-EnvValues -EnvValues (New-ValidEnv @{ DB_PASSWORD = $Password }) -ComposeFiles $script:SqlServerFiles

            ($errors -join "`n") | Should -Match 'DB_PASSWORD'
            ($errors -join "`n") | Should -Match 'SQL Server'
        }

        It 'accepts a SQL Server DB_PASSWORD "<Password>" with 8+ characters from 3 classes' -ForEach @(
            @{ Password = 'Abcdefg1' }
            @{ Password = 'abcdefg1!' }
            @{ Password = 'ABCDEFG!1' }
            @{ Password = 'Abcdefg!' }
        ) {
            Test-EnvValues -EnvValues (New-ValidEnv @{ DB_PASSWORD = $Password }) -ComposeFiles $script:SqlServerFiles | Should -BeNullOrEmpty
        }

        It 'rejects SKIP_PLATFORM "<Value>": only true skips the platform, and anything else would silently run it' -ForEach @(
            @{ Value = '1' }
            @{ Value = 'yes' }
            @{ Value = 'on' }
        ) {
            $errors = Test-EnvValues -EnvValues (New-ValidEnv @{ SKIP_PLATFORM = $Value }) -ComposeFiles $script:PostgresFiles

            ($errors -join "`n") | Should -Match "SKIP_PLATFORM in \.env is '$Value'"
            # The message names every value the rule accepts.
            ($errors -join "`n") | Should -Match 'true to skip the platform.*false or empty to run it'
        }

        It 'accepts SKIP_PLATFORM "<Value>"' -ForEach @(
            @{ Value = '' }
            @{ Value = 'true' }
            @{ Value = ' TRUE ' }
            @{ Value = 'false' }
        ) {
            Test-EnvValues -EnvValues (New-ValidEnv @{ SKIP_PLATFORM = $Value }) -ComposeFiles $script:PostgresFiles | Should -BeNullOrEmpty
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

        It 'names the standard FRONTEND_PORT of the mode: <Expected> (HTTPS <Https>)' -ForEach @(
            @{ Https = $true; Expected = '443' }
            @{ Https = $false; Expected = '80' }
        ) {
            $files = [string[]]@('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/frontend.yml') + @(if ($Https) { 'docker-compose/https.yml' })

            { Get-RequiredPorts -EnvValues (New-ValidEnv @{ FRONTEND_PORT = '' }) -ComposeFiles $files } |
                Should -Throw -ExceptionType ([System.FormatException]) -ExpectedMessage "*FRONTEND_PORT is empty*standard one is $Expected)*"
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
