BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

Describe 'Native command helpers' -Tag 'Unit' {
    Context 'ConvertTo-CommandLine' {
        # Windows command-line rules (CommandLineToArgvW): a quoted argument escapes " as \" and doubles the backslashes
        # that precede a quote, including the closing one.
        It 'quotes <Name>' -ForEach @(
            @{ Name = 'nothing that needs no quoting'; Arguments = @('dotnet', 'run', '--no-build'); Expected = 'dotnet run --no-build' }
            @{ Name = 'an argument with a space'; Arguments = @('--project', 'a b/c.csproj'); Expected = '--project "a b/c.csproj"' }
            @{ Name = 'an empty argument'; Arguments = @('--urls', ''); Expected = '--urls ""' }
            @{ Name = 'an embedded quote'; Arguments = @('say "hi"'); Expected = '"say \"hi\""' }
            @{ Name = 'a trailing backslash of a quoted argument'; Arguments = @('C:\My Folder\'); Expected = '"C:\My Folder\\"' }
        ) {
            ConvertTo-CommandLine $Arguments | Should -BeExactly $Expected
        }

        It 'returns an empty string for no arguments' {
            ConvertTo-CommandLine @() | Should -BeExactly ''
        }
    }

    Context 'Assert-NativeSuccess' {
        It 'does nothing after exit code 0' {
            $global:LASTEXITCODE = 0
            { Assert-NativeSuccess 'step' } | Should -Not -Throw
        }

        It 'throws with the description and the exit code after a failure' {
            $global:LASTEXITCODE = 3
            { Assert-NativeSuccess 'docker build' } | Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage 'docker build failed with exit code 3.'
            $global:LASTEXITCODE = 0
        }
    }
}

Describe 'Test-DockerComposeAvailable' -Tag 'Unit' {
    It 'asks docker once and remembers a positive answer (Invoke-DockerCompose checks before every call)' {
        $script:DockerComposeAvailable = $false
        $script:probes = 0
        function script:docker { $script:probes++; $global:LASTEXITCODE = 0 }
        Mock Get-Command { [pscustomobject]@{ Name = 'docker' } } -ParameterFilter { $Name -eq 'docker' }

        Test-DockerComposeAvailable | Should -BeTrue
        Test-DockerComposeAvailable | Should -BeTrue

        $script:probes | Should -Be 1
        Remove-Item -LiteralPath function:script:docker
        $script:DockerComposeAvailable = $false
    }
}
