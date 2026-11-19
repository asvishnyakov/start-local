BeforeAll {
    $script:Runner = Join-Path $PSScriptRoot '../Invoke-Tests.ps1'

    function Invoke-Runner {
        # Runs the tier runner in a child pwsh over a scratch test root and returns its exit code.
        param([Parameter(Mandatory)][string]$Root, [string]$Tier = 'Unit')

        $null = & pwsh -NoProfile -File $script:Runner -Tier $Tier -Root $Root 2>&1
        $LASTEXITCODE
    }

    function New-TestFile {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Body)

        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
        Set-Content -LiteralPath $Path -Value $Body
    }
}

Describe 'Invoke-Tests.ps1' -Tag 'Unit' {
    It 'exits 0 when every test passes' {
        $root = Join-Path $TestDrive 'pass'
        New-TestFile (Join-Path $root 'unit/Pass.Tests.ps1') "Describe 'd' -Tag 'Unit' { It 'passes' { 1 | Should -Be 1 } }"
        Invoke-Runner -Root $root | Should -Be 0
    }

    It 'fails when the tier folder has no tests' {
        $root = Join-Path $TestDrive 'empty'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'unit')
        Invoke-Runner -Root $root | Should -Not -Be 0
    }

    It 'fails when the tier folder is missing' {
        $root = Join-Path $TestDrive 'missing'
        $null = New-Item -ItemType Directory -Force -Path $root
        Invoke-Runner -Root $root | Should -Not -Be 0
    }

    It 'fails with 256 failed tests (an exit code that is a multiple of 256 must not wrap to 0)' {
        $root = Join-Path $TestDrive 'fail256'
        New-TestFile (Join-Path $root 'unit/Fail.Tests.ps1') "Describe 'd' -Tag 'Unit' { It 'fails <_>' -ForEach (1..256) { 1 | Should -Be 2 } }"
        Invoke-Runner -Root $root | Should -Not -Be 0
    }

    It 'runs a test in the tier folder even when its tag names another tier' {
        $root = Join-Path $TestDrive 'mistagged'
        New-TestFile (Join-Path $root 'unit/Mistagged.Tests.ps1') "Describe 'd' -Tag 'Compose' { It 'fails' { 1 | Should -Be 2 } }"
        Invoke-Runner -Root $root | Should -Not -Be 0
    }
}
