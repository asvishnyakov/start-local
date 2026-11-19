BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    $script:RemoveScript = Join-Path (Get-TestRepositoryRoot) 'remove.ps1'

    # A solution folder with a layout 2 .env, a docker-compose.yml (so remove.ps1 brings the stack down) and some payload.
    function script:New-RemoveScriptFolder {
        $folder = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))/rm-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
        $null = New-Item -ItemType Directory -Path (Join-Path $folder 'backend/certs') -Force
        Set-Content -LiteralPath (Join-Path $folder '.env') -Value 'START_LOCAL_LAYOUT=2', 'VOLUME_PREFIX=acme'
        foreach ($child in 'docker-compose.yml', 'start.ps1', '.env.example', 'backend/certs/localhost.pem') {
            Set-Content -LiteralPath (Join-Path $folder $child) -Value 'x'
        }
        $folder
    }

    # A fake docker on PATH: it logs every call, one line of arguments each, and answers only what remove.ps1 asks.
    # `compose ... down` exits with $DownExitCode; anything it does not know fails, so an unexpected call shows.
    function script:New-FakeDocker {
        param([int]$DownExitCode = 0)
        $bin = Join-Path $TestDrive "fake-docker-$([guid]::NewGuid().ToString('N'))"
        $log = New-FakeCommand $bin 'docker' @"
case "`$*" in
  'compose version'*) echo 'Docker Compose version v2.40.3'; exit 0 ;;
  'compose '*down*) exit $DownExitCode ;;
  'info '*) echo '28.0.0'; exit 0 ;;
  'volume rm '*) exit 0 ;;
  'rmi '*) exit 0 ;;
esac
echo "fake docker: unexpected call: `$*" >&2
exit 99
"@
        [pscustomobject]@{ Bin = $bin; Log = $log }
    }


    function script:Invoke-RemoveWithFakeDocker {
        param([Parameter(Mandatory)][pscustomobject]$Docker, [string[]]$Arguments)
        $previousPath = $env:PATH
        $env:PATH = "$($Docker.Bin)$([System.IO.Path]::PathSeparator)$previousPath"
        try {
            $output = & pwsh -NoProfile -File $script:RemoveScript @Arguments *>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
        finally {
            $env:PATH = $previousPath
        }
    }
}

Describe 'remove.ps1 with a fake docker' -Tag 'Unit' {
    It '-keepData keeps .env and the folder, deletes every other child, and removes no volume (P039)' -Skip:$IsWindows {
        $folder = New-RemoveScriptFolder
        $docker = New-FakeDocker

        $result = Invoke-RemoveWithFakeDocker $docker @('-nonInteractive', '-keepData', '-solutionFolder', $folder)

        $result.ExitCode | Should -Be 0 -Because $result.Output
        $folder | Should -Exist
        Join-Path $folder '.env' | Should -Exist
        @(Get-ChildItem -LiteralPath $folder -Force | ForEach-Object { $_.Name }) | Should -Be @('.env')
        $calls = @(Get-FakeCommandCalls $docker.Log)
        $calls | Should -Contain 'compose down --remove-orphans'
        @($calls | Where-Object { $_ -like 'compose*down*' -and $_ -match '(^| )-v( |$)' }) | Should -HaveCount 0
        @($calls | Where-Object { $_ -like 'volume rm*' }) | Should -HaveCount 0
        # The images go even when the data stays.
        @($calls | Where-Object { $_ -like 'rmi *' }) | Should -HaveCount 2
    }

    It 'a full remove passes -v and removes the volumes by name (the contrast to -keepData)' -Skip:$IsWindows {
        $folder = New-RemoveScriptFolder
        $docker = New-FakeDocker

        $result = Invoke-RemoveWithFakeDocker $docker @('-nonInteractive', '-solutionFolder', $folder)

        $result.ExitCode | Should -Be 0 -Because $result.Output
        $folder | Should -Not -Exist
        $calls = @(Get-FakeCommandCalls $docker.Log)
        $calls | Should -Contain 'compose down -v --remove-orphans'
        $calls | Should -Contain 'volume rm acme_postgres_data'
    }

    It 'aborts with exit 1 and deletes nothing when docker compose down fails (P040, <Mode>)' -Skip:$IsWindows -ForEach @(
        @{ Mode = 'full'; Arguments = @() }
        @{ Mode = 'keepData'; Arguments = @('-keepData') }
    ) {
        $folder = New-RemoveScriptFolder
        $before = @(Get-ChildItem -LiteralPath $folder -Recurse -Force | ForEach-Object { $_.FullName } | Sort-Object)
        $docker = New-FakeDocker -DownExitCode 3

        $result = Invoke-RemoveWithFakeDocker $docker (@('-nonInteractive', '-solutionFolder', $folder) + $Arguments)

        $result.ExitCode | Should -Be 1
        $result.Output | Should -BeLike '*failed with exit code 3*'
        @(Get-ChildItem -LiteralPath $folder -Recurse -Force | ForEach-Object { $_.FullName } | Sort-Object) | Should -Be $before
        $calls = @(Get-FakeCommandCalls $docker.Log)
        @($calls | Where-Object { $_ -like 'compose*down*' }) | Should -HaveCount 1
        @($calls | Where-Object { $_ -like 'info*' -or $_ -like 'volume rm*' -or $_ -like 'rmi *' }) | Should -HaveCount 0
    }
}
