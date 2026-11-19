# Contracts between the scripts and the compose files that only Compose itself can confirm: the empty-secret guards,
# the .env parser against Compose's own reading, and the volume names that remove.ps1 deletes.
BeforeDiscovery {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)

    # The parser-parity table of EnvFile.Tests.ps1, read from its AST so there is one copy of it: the -TestCases of the
    # It whose name says 'like Docker Compose'.
    $script:parityCases = @()
    $envFileTests = Join-Path $PSScriptRoot '../unit/EnvFile.Tests.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($envFileTests, [ref]$null, [ref]$null)
    $parityIt = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'It' -and
            $node.CommandElements.Count -gt 1 -and $node.CommandElements[1].Extent.Text -like '*like Docker Compose*'
        }, $true)
    if ($parityIt) {
        $elements = [object[]]$parityIt.CommandElements
        $testCasesIndex = [array]::FindIndex($elements, [Predicate[object]] {
                param($element)
                $element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq 'TestCases'
            })
        if ($testCasesIndex -ge 0 -and $testCasesIndex + 1 -lt $elements.Count) {
            $script:parityCases = @($elements[$testCasesIndex + 1].SafeGetValue() | ForEach-Object {
                    # Prefixed keys, so no variable of the test process (which Compose prefers over .env) can shadow them.
                    @{ Line = "SLP_$($_.Line)"; Key = 'SLP_' + ($_.Line -split '=', 2)[0]; Expected = $_.Expected }
                })
        }
    }

    # Lines a hand-edited .env can hold that Set-EnvValue also writes to (see tests/unit/EnvFileEdges.Tests.ps1).
    $script:editedLineCases = @(
        @{ Name = 'an export prefix'; Lines = @('export SLP_X=1'); Key = 'SLP_X'; Expected = '1' }
        @{ Name = 'spaces around the key'; Lines = @('  SLP_Y = 2'); Key = 'SLP_Y'; Expected = '2' }
        @{ Name = 'a tab before the equals sign'; Lines = @("SLP_T`t=3"); Key = 'SLP_T'; Expected = '3' }
        @{ Name = 'a spaced export prefix and an inline comment'; Lines = @(' export  SLP_E=4 # c'); Key = 'SLP_E'; Expected = '4' }
        @{ Name = 'a duplicated key (the last one wins)'; Lines = @('SLP_Z=1', 'SLP_Z=2'); Key = 'SLP_Z'; Expected = '2' }
        @{ Name = 'an exported then a plain duplicate'; Lines = @('export SLP_W=1', 'SLP_W=2'); Key = 'SLP_W'; Expected = '2' }
    )

    # Each secret with a compose list whose files guard it with ${KEY:?KEY is empty in .env}.
    $script:secretCases = @(
        foreach ($provider in 'postgres', 'mysql', 'sqlserver') {
            @{ Key = 'DB_PASSWORD'; Label = "$provider"; Requested = @('docker-compose.yml', "docker-compose/$provider.yml") }
            @{ Key = 'DB_PASSWORD'; Label = "$provider with a platform"; Requested = @('docker-compose.yml', "docker-compose/$provider.yml", 'docker-compose/platform.yml') }
        }
        @{ Key = 'REDIS_PASSWORD'; Label = 'redis'; Requested = @('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/redis.yml') }
        @{ Key = 'ELASTIC_PASSWORD'; Label = 'elasticsearch'; Requested = @('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/elasticsearch.yml') }
        @{ Key = 'ELASTIC_PASSWORD'; Label = 'elasticsearch, https'; Requested = @('docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/elasticsearch.yml') }
        @{ Key = 'KIBANA_PASSWORD'; Label = 'kibana'; Requested = @('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/elasticsearch.yml', 'docker-compose/kibana.yml') }
        @{ Key = 'KIBANA_PASSWORD'; Label = 'kibana, https'; Requested = @('docker-compose.yml', 'docker-compose/https.yml', 'docker-compose/postgres.yml', 'docker-compose/elasticsearch.yml', 'docker-compose/kibana.yml') }
    )
}

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    function script:Get-ComposeEnvironment {
        # The environment Compose gives service t of a one-service project whose .env holds $Lines, for each of $Keys.
        param([Parameter(Mandatory)][string[]]$Lines, [Parameter(Mandatory)][string[]]$Keys)

        $folder = Join-Path (Get-TestScratchRoot) "sl-parity-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $folder -Force
        try {
            $composeLines = @('name: slparity', 'services:', '  t:', '    image: alpine', '    environment:') +
                @($Keys | Sort-Object -Unique | ForEach-Object { "      - $_=`${$_}" })
            [System.IO.File]::WriteAllText((Join-Path $folder 'docker-compose.yml'), ($composeLines -join "`n") + "`n")
            [System.IO.File]::WriteAllText((Join-Path $folder '.env'), ($Lines -join "`n") + "`n")
            [pscustomobject]@{
                Compose = (Invoke-ComposeConfigJson $folder).services.t.environment
                Parser  = Read-EnvFile (Join-Path $folder '.env')
            }
        }
        finally {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Compose contract: an empty secret stops docker compose config' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    It '<Key> empty (<Label>) fails naming the key' -ForEach $script:secretCases {
        [string[]]$composeFiles = Update-ComposeFileList -ComposeFiles $Requested -HasSourceModules $false
        $filled = New-ComposeFixtureFolder -ComposeFiles $composeFiles
        $empty = New-ComposeFixtureFolder -ComposeFiles $composeFiles -EnvOverrides @{ $Key = '' }
        try {
            # The control: the same files with the secret filled pass.
            { Invoke-ComposeConfigJson $filled } | Should -Not -Throw
            { Invoke-ComposeConfigJson $empty } | Should -Throw "*$Key is empty in .env*"
        }
        finally {
            foreach ($folder in $filled, $empty) {
                Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'every secret key has a case' -ForEach @(@{ CaseKeys = @($script:secretCases | ForEach-Object { $_.Key }) }) {
        foreach ($key in $script:SecretKeys) {
            $CaseKeys | Should -Contain $key -Because "$key needs a guard test"
        }
    }
}

# The cases reach the run phase through -ForEach: variables of BeforeDiscovery exist only during discovery.
Describe 'Compose contract: the .env parser reads values as Compose does' -Tag 'Compose' -Skip:(-not $script:hasDocker) -ForEach @(@{ ParityCases = $script:parityCases }) {
    BeforeAll {
        $script:parityResult = if (@($ParityCases).Count -gt 0) {
            Get-ComposeEnvironment -Lines @($ParityCases | ForEach-Object { $_.Line }) -Keys @($ParityCases | ForEach-Object { $_.Key })
        }
    }

    It 'the parity table of EnvFile.Tests.ps1 was found' {
        # The cases come from the AST of that file; an empty list would make the table below vanish silently.
        @($ParityCases).Count | Should -BeGreaterOrEqual 1 -Because "the It 'reads unquoted values like Docker Compose' in tests/unit/EnvFile.Tests.ps1 must exist and have -TestCases"
    }

    It 'table line <Line>: Compose, Get-EnvValue and the table agree' -ForEach $script:parityCases {
        $composeValue = [string]$script:parityResult.Compose.$Key

        $composeValue | Should -BeExactly $Expected -Because 'the table must hold what Compose reads'
        Get-EnvValue $script:parityResult.Parser $Key | Should -BeExactly $composeValue
    }

    It '<Name>: Compose and Get-EnvValue agree' -ForEach $script:editedLineCases {
        $result = Get-ComposeEnvironment -Lines $Lines -Keys @($Key)

        [string]$result.Compose.$Key | Should -BeExactly $Expected
        Get-EnvValue $result.Parser $Key | Should -BeExactly $Expected
    }

    It 'a value written by Set-EnvValue over an edited line reads back the same in Compose' {
        $document = ConvertFrom-EnvText ((@(' export  SLP_A=old # why', 'SLP_B=1', 'SLP_B=2', '  SLP_C = x') -join "`n") + "`n")
        Set-EnvValue $document 'SLP_A' 'new'
        Set-EnvValue $document 'SLP_B' '3'
        Set-EnvValue $document 'SLP_C' 'y'

        $result = Get-ComposeEnvironment -Lines @((ConvertTo-EnvText $document) -split "`n" | Where-Object { $_ }) -Keys 'SLP_A', 'SLP_B', 'SLP_C'

        [string]$result.Compose.SLP_A | Should -BeExactly 'new'
        [string]$result.Compose.SLP_B | Should -BeExactly '3'
        [string]$result.Compose.SLP_C | Should -BeExactly 'y'
    }
}

Describe 'Compose contract: remove.ps1 deletes the volumes the compose files declare' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    BeforeAll {
        # Every provider with every feature, in HTTPS mode: the union of the named volumes Compose creates.
        $script:declaredVolumes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $script:certsVolumes = [System.Collections.Generic.List[string]]::new()
        foreach ($provider in 'postgres', 'mysql', 'sqlserver') {
            [string[]]$composeFiles = Get-DefaultComposeFiles -Provider $provider -Https $true
            $composeFiles += Get-ComposeFileName 'es-limited.yml'
            [string[]]$composeFiles = Update-ComposeFileList -ComposeFiles $composeFiles -HasSourceModules $false
            $folder = New-ComposeFixtureFolder -ComposeFiles $composeFiles -EnvOverrides @{ VOLUME_PREFIX = 'slvol' }
            try {
                $config = Invoke-ComposeConfigJson $folder
                foreach ($volume in $config.volumes.PSObject.Properties.Value) {
                    $null = $script:declaredVolumes.Add($volume.name)
                }
                $script:certsVolumes.Add($config.volumes.certs.name)
                $script:certsVolumeName = Get-CertsVolumeName -Document (Read-EnvFile (Join-Path $folder '.env')) -SolutionFolder $folder
            }
            finally {
                Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $script:removedVolumes = Get-SolutionVolumeNames -Prefix 'slvol'
    }

    It 'the compose files declare named volumes' {
        $script:declaredVolumes.Count | Should -BeGreaterThan 0
    }

    It 'every declared volume is one Get-SolutionVolumeNames lists' {
        foreach ($name in $script:declaredVolumes) {
            $script:removedVolumes | Should -Contain $name -Because "remove.ps1 would leave the volume $name behind"
        }
    }

    It 'Get-SolutionVolumeNames lists no volume the compose files no longer declare, except the legacy Redis volume' {
        # redisdata: layout 1 had a Redis volume; a full remove still deletes it (scripts/migrate.ps1).
        foreach ($name in $script:removedVolumes | Where-Object { $_ -cne 'slvol_redisdata' }) {
            $script:declaredVolumes.Contains($name) | Should -BeTrue -Because "$name is listed for removal but no compose file declares it"
        }
    }

    It 'Get-CertsVolumeName names the certificates volume of docker-compose/https.yml' {
        $script:certsVolumes | Should -Not -BeNullOrEmpty
        foreach ($name in $script:certsVolumes) {
            $script:certsVolumeName | Should -BeExactly $name
        }
    }
}
