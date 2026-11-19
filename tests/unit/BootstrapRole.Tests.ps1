# install.ps1 in the bootstrap role (no -payloadPath), run in-process (P041): the download is a local zip handed out by a
# mocked Invoke-WebRequest, so nothing reaches GitHub. The payload installer inside the zip is a recorder.
BeforeAll {
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    $script:InstallScript = Join-Path (Get-TestRepositoryRoot) 'install.ps1'

    # A GitHub-like archive: one top-level folder start-local-<Name>. With -WithInstaller, its install.ps1 records the
    # parameters it is bound with into $global:BootstrapRecordPath and exits with $global:BootstrapPayloadExitCode.
    function script:New-PayloadZip {
        param([Parameter(Mandatory)][string]$Name, [switch]$WithInstaller)
        $staging = Join-Path $TestDrive "zip-$([guid]::NewGuid().ToString('N'))"
        $root = Join-Path $staging "start-local-$Name"
        $null = New-Item -ItemType Directory -Path $root -Force
        if ($WithInstaller) {
            Set-Content -LiteralPath (Join-Path $root 'install.ps1') -Value @'
param([string]$targetFolder, [string]$branch, [string]$releaseChannel, [bool]$skipSampleData, [switch]$nonInteractive, [string]$payloadPath)
$PSBoundParameters | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $global:BootstrapRecordPath
exit $global:BootstrapPayloadExitCode
'@
        }
        else {
            Set-Content -LiteralPath (Join-Path $root 'VirtoLocal_create_local_files.ps1') -Value '# the old installer'
        }
        $zipPath = Join-Path $staging 'archive.zip'
        Compress-Archive -LiteralPath $root -DestinationPath $zipPath
        $zipPath
    }

    # Runs the bootstrap with $env:TMPDIR pointed at an empty folder of its own, so its work folder is easy to watch.
    function script:Invoke-Bootstrap {
        param([Parameter(Mandatory)][string]$ZipPath, [hashtable]$Arguments = @{}, [int]$PayloadExitCode = 0)
        $global:BootstrapZipPath = $ZipPath
        $global:BootstrapRecordPath = Join-Path $TestDrive "record-$([guid]::NewGuid().ToString('N')).json"
        $global:BootstrapPayloadExitCode = $PayloadExitCode
        $global:BootstrapDownload = $null
        $temp = Join-Path $TestDrive "temp-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $temp
        $previousTemp = $env:TMPDIR
        $env:TMPDIR = $temp
        try {
            $global:LASTEXITCODE = 0
            $output = & $script:InstallScript @Arguments *>&1 | Out-String
            $exitCode = $LASTEXITCODE
        }
        finally {
            $env:TMPDIR = $previousTemp
        }
        $record = if (Test-Path -LiteralPath $global:BootstrapRecordPath) { Get-Content -LiteralPath $global:BootstrapRecordPath -Raw | ConvertFrom-Json }
        [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $output
            Record   = $record
            Download = $global:BootstrapDownload
            TempLeft = @(Get-ChildItem -LiteralPath $temp -Force)
        }
    }
}

AfterAll {
    Remove-Variable -Name BootstrapZipPath, BootstrapRecordPath, BootstrapPayloadExitCode, BootstrapDownload -Scope Global -ErrorAction Ignore
}

Describe 'install.ps1 bootstrap role' -Tag 'Unit' {
    BeforeEach {
        Mock Invoke-WebRequest {
            $global:BootstrapDownload = [pscustomobject]@{ Uri = "$Uri"; OutFile = $OutFile }
            Copy-Item -LiteralPath $global:BootstrapZipPath -Destination $OutFile
        }
        Mock Invoke-RestMethod { throw 'the release API must not be called when -branch is given' }
    }

    It 'downloads the ref, hands the bound parameters, the payload and the ref to the payload installer, and removes its work folder' {
        $zip = New-PayloadZip -Name 'release-1.0' -WithInstaller

        $run = Invoke-Bootstrap $zip @{ branch = 'release/1.0'; targetFolder = 'Shop'; releaseChannel = 'stable'; skipSampleData = $true; nonInteractive = $true }

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Download.Uri | Should -BeExactly 'https://github.com/VirtoCommerce/start-local/archive/release/1.0.zip'
        $run.Record.targetFolder | Should -BeExactly 'Shop'
        $run.Record.branch | Should -BeExactly 'release/1.0'
        $run.Record.releaseChannel | Should -BeExactly 'stable'
        $run.Record.skipSampleData | Should -BeTrue
        $run.Record.nonInteractive.IsPresent | Should -BeTrue
        Split-Path -Leaf $run.Record.payloadPath | Should -BeExactly 'start-local-release-1.0'
        # The work folder that held the zip and the extracted payload is gone.
        Split-Path -Parent $run.Download.OutFile | Should -Not -Exist
        $run.TempLeft | Should -HaveCount 0
    }

    It 'passes the exit code <ExitCode> of the payload installer through' -ForEach @(
        @{ ExitCode = 5 }
        @{ ExitCode = 1 }
    ) {
        $zip = New-PayloadZip -Name 'main' -WithInstaller

        $run = Invoke-Bootstrap $zip @{ branch = 'main'; nonInteractive = $true } -PayloadExitCode $ExitCode

        $run.ExitCode | Should -Be $ExitCode
        $run.Record | Should -Not -BeNullOrEmpty
        $run.TempLeft | Should -HaveCount 0
    }

    It 'installs the latest release tag when no -branch is given, and forwards it as the branch' {
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v2.0.0' } }
        $zip = New-PayloadZip -Name '2.0.0' -WithInstaller

        $run = Invoke-Bootstrap $zip @{ nonInteractive = $true }

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Download.Uri | Should -BeExactly 'https://github.com/VirtoCommerce/start-local/archive/v2.0.0.zip'
        $run.Record.branch | Should -BeExactly 'v2.0.0'
    }

    It 'refuses a ref without install.ps1 with the legacy message, exits 1 and removes its work folder' {
        $zip = New-PayloadZip -Name 'old'

        $run = Invoke-Bootstrap $zip @{ branch = 'old'; nonInteractive = $true }

        $run.ExitCode | Should -Be 1
        $run.Output | Should -BeLike "*'old' has no install.ps1: it is the old start-local layout*"
        $run.Output | Should -BeLike '*VirtoLocal_create_local_files.ps1 -branch old*'
        $run.Record | Should -BeNullOrEmpty
        $run.TempLeft | Should -HaveCount 0
    }

    It 'exits 1, runs nothing and removes its work folder when the download fails' {
        Mock Invoke-WebRequest { $global:BootstrapDownload = [pscustomobject]@{ Uri = "$Uri"; OutFile = $OutFile }; throw 'Response status code does not indicate success: 404 (Not Found).' }
        $zip = New-PayloadZip -Name 'missing' -WithInstaller

        $run = Invoke-Bootstrap $zip @{ branch = 'missing'; nonInteractive = $true }

        $run.ExitCode | Should -Be 1
        $run.Output | Should -BeLike '*404 (Not Found)*'
        $run.Record | Should -BeNullOrEmpty
        $run.TempLeft | Should -HaveCount 0
    }
}
