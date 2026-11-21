# The scripts read .env as Docker Compose does (scripts/compose-env-value.ps1): this compares both readings of one file
# on the Compose of this machine. Compose reads it as an env_file and prints the service environment as JSON, which
# keeps line breaks and leaves the process environment out of the values themselves; it doubles every '$', which the
# comparison undoes.
BeforeDiscovery {
    $script:hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)
}

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    $script:Fixture = Join-Path $PSScriptRoot '../fixtures/env/compose-parity.env'
}

Describe 'Compose parity of .env values' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    BeforeAll {
        $env:SL_PARITY_ONLY_OS = 'os'
        $env:SL_PARITY_BOTH = 'fromos'
        $folder = Join-Path $TestDrive 'parity'
        $null = New-Item -ItemType Directory -Path $folder
        Copy-Item -LiteralPath $script:Fixture -Destination (Join-Path $folder 'values.env')
        Set-Content -LiteralPath (Join-Path $folder 'compose.yml') -Value "services:`n  x:`n    image: alpine`n    env_file: [values.env]"
        # An empty project .env: the values come from the env_file alone.
        Set-Content -LiteralPath (Join-Path $folder 'empty.env') -Value ''
        $json = & docker compose --project-directory $folder -f (Join-Path $folder 'compose.yml') --env-file (Join-Path $folder 'empty.env') config --format json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose config failed: $json"
        }
        $script:ComposeValues = @{}
        foreach ($property in ($json | ConvertFrom-Json).services.x.environment.PSObject.Properties) {
            $script:ComposeValues[$property.Name] = ([string]$property.Value).Replace('$$', '$')
        }
        $script:ScriptValues = Get-EnvTable -Document (Read-EnvFile -Path $script:Fixture)
    }

    AfterAll {
        Remove-Item Env:SL_PARITY_ONLY_OS, Env:SL_PARITY_BOTH -ErrorAction Ignore
    }

    It 'reads the same keys' {
        @($script:ScriptValues.Keys | Sort-Object) | Should -Be @($script:ComposeValues.Keys | Sort-Object)
    }

    It 'reads every value as Compose does' {
        $differences = foreach ($key in $script:ComposeValues.Keys) {
            if ($script:ScriptValues[$key] -cne $script:ComposeValues[$key]) {
                "$key`: scripts '$($script:ScriptValues[$key])', Compose '$($script:ComposeValues[$key])'"
            }
        }
        @($differences) | Should -BeNullOrEmpty
    }
}
