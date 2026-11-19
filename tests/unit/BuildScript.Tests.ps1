# build.ps1 end to end with a fake vc-build and a fake docker on PATH (Linux and macOS): the modules-folder discovery path,
# the stable:<N> fail-fast and the hand-off to start.ps1 (P056). Real builds and downloads are out of scope.
BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    # A solution folder for a Docker platform in HTTP mode, without a storefront (no frontend download), whose start.ps1
    # records its bound parameters into start.json next to it and exits with the code in start-exit-code.
    function script:New-BuildFolder {
        param([hashtable]$Values = @{}, [int]$StartExitCode = 0)
        $folder = New-TestSolutionFolder -Values $Values
        Set-Content -LiteralPath (Join-Path $folder 'start-exit-code') -Value $StartExitCode
        Set-Content -LiteralPath (Join-Path $folder 'start.ps1') -Value @'
param([string]$solutionFolder, [bool]$skipSampleData, [switch]$nonInteractive, [Parameter(ValueFromRemainingArguments)]$rest)
$PSBoundParameters | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'start.json')
exit [int](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'start-exit-code'))
'@
        $folder
    }

    # Runs build.ps1 of $Folder in-process with the fake commands first on PATH. Returns the exit code and the output.
    function script:Invoke-BuildScript {
        param([Parameter(Mandatory)][string]$Folder, [hashtable]$Arguments = @{})
        $previousPath = $env:PATH
        $env:PATH = "$script:FakeBin$([System.IO.Path]::PathSeparator)$previousPath"
        try {
            $global:LASTEXITCODE = 0
            $output = & (Join-Path $Folder 'build.ps1') -solutionFolder $Folder -nonInteractive -skipSampleData $true @Arguments *>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
        finally {
            $env:PATH = $previousPath
        }
    }

    # The value after $Name in a vc-build argument line.
    function script:Get-ArgumentValue {
        param([Parameter(Mandatory)][string]$Line, [Parameter(Mandatory)][string]$Name)
        $tokens = $Line -split ' '
        $index = [array]::IndexOf($tokens, $Name)
        if ($index -lt 0) { return $null }
        $tokens[$index + 1]
    }
}

Describe 'build.ps1' -Tag 'Unit' -Skip:$IsWindows {
    BeforeEach {
        $script:FakeBin = Join-Path $TestDrive "fake-bin-$([guid]::NewGuid().ToString('N'))"
        $script:VcBuildLog = New-FakeCommand $script:FakeBin 'vc-build'
        $script:DockerLog = New-FakeCommand $script:FakeBin 'docker'
        Mock Save-PlatformDockerfile { }
        # Nothing here may reach the network.
        Mock Invoke-WebRequest { throw 'build.ps1 tried to download from the network' }
        Mock Invoke-RestMethod { throw 'build.ps1 tried to call a web API' }
        Mock Get-StableJson { [pscustomobject]@{ '16' = [pscustomobject]@{}; '17' = [pscustomobject]@{} } }
    }

    Context 'module discovery path' {
        It 'makes vc-build install into the modules folder of MODULE_SOURCE_PATHS' {
            $modules = Join-Path $TestDrive "modules-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $modules
            $folder = New-BuildFolder -Values @{ MODULE_SOURCE_PATHS = $modules }

            $run = Invoke-BuildScript $folder

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $calls = @(Get-FakeCommandCalls $script:VcBuildLog)
            $calls | Should -HaveCount 1
            $calls[0] | Should -BeLike 'install *'
            Get-ArgumentValue $calls[0] '--discovery-path' | Should -Be $modules
            Get-ArgumentValue $calls[0] '--root' | Should -Be (Join-Path $folder 'backend/publish')
            $run.Output | Should -BeLike "*Installing the modules into $modules (MODULE_SOURCE_PATHS).*"
        }

        It 'installs into the publish folder without a modules folder, then builds the image and removes the publish folder' {
            $folder = New-BuildFolder
            $projectName = Get-SolutionProjectName -Document (Read-EnvFile (Join-Path $folder '.env')) -SolutionFolder $folder

            $run = Invoke-BuildScript $folder

            $run.ExitCode | Should -Be 0 -Because $run.Output
            Get-ArgumentValue @(Get-FakeCommandCalls $script:VcBuildLog)[0] '--discovery-path' | Should -Be (Join-Path $folder 'backend/publish/modules')
            Should -Invoke Save-PlatformDockerfile -Times 1 -Exactly -ParameterFilter { $Destination -eq (Join-Path $folder 'backend') }
            @(Get-FakeCommandCalls $script:DockerLog) | Should -Be @("build --no-cache -t vc-platform:$projectName-latest $(Join-Path $folder 'backend')")
            Join-Path $folder 'backend/publish' | Should -Not -Exist
        }

        It 'exits 1 and builds no image when vc-build fails' {
            $script:VcBuildLog = New-FakeCommand $script:FakeBin 'vc-build' 'exit 4'
            $folder = New-BuildFolder

            $run = Invoke-BuildScript $folder

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike '*vc-build install failed with exit code 4*'
            Get-FakeCommandCalls $script:DockerLog | Should -HaveCount 0
            Join-Path $folder 'start.json' | Should -Not -Exist
        }
    }

    Context 'stable:N fail-fast' {
        It 'fails fast when stable.json does not list the bundle' {
            $folder = New-BuildFolder -Values @{ RELEASE_CHANNEL = 'stable:13' }

            $run = Invoke-BuildScript $folder

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike '*Stable 13 is not listed in bundles/stable.json*'
            Get-FakeCommandCalls $script:VcBuildLog | Should -HaveCount 0
            Get-FakeCommandCalls $script:DockerLog | Should -HaveCount 0
            Join-Path $folder 'start.json' | Should -Not -Exist
        }

        It 'passes a listed bundle to vc-build' {
            $folder = New-BuildFolder -Values @{ RELEASE_CHANNEL = 'stable:16' }

            $run = Invoke-BuildScript $folder

            $run.ExitCode | Should -Be 0 -Because $run.Output
            @(Get-FakeCommandCalls $script:VcBuildLog)[0] | Should -BeLike 'install -v 16 *'
        }
    }

    Context 'hand-off to start.ps1' {
        It 'forwards only the per-run switches and passes the exit code <ExitCode> through' -ForEach @(
            @{ ExitCode = 0 }
            @{ ExitCode = 7 }
        ) {
            $folder = New-BuildFolder -StartExitCode $ExitCode

            $run = Invoke-BuildScript $folder

            $run.ExitCode | Should -Be $ExitCode -Because $run.Output
            $bound = Get-Content -LiteralPath (Join-Path $folder 'start.json') -Raw | ConvertFrom-Json
            @($bound.PSObject.Properties.Name | Sort-Object) | Should -Be @('nonInteractive', 'skipSampleData')
            $bound.skipSampleData | Should -BeTrue
            $bound.nonInteractive.IsPresent | Should -BeTrue
        }
    }
}
