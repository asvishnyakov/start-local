BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    $script:SampleDataScript = Join-Path $PSScriptRoot '../../scripts/setup-sampledata.ps1'
}

Describe 'setup-sampledata.ps1' -Tag 'Unit' {
    BeforeEach {
        Mock Start-Sleep { }
        $global:LASTEXITCODE = 0
    }

    It 'finishes at once, without polling, when the platform has no sample data to install (an empty reply)' {
        # The backup-restore module answers autoinstall with an empty 200 when there is nothing to install.
        Mock Invoke-RestMethod { $null } -ParameterFilter { $Uri -like '*/sampledata/autoinstall' }
        Mock Invoke-RestMethod { throw 'polled' } -ParameterFilter { "$Uri" -like '*/pushnotifications' }

        $output = & $script:SampleDataScript -ApiUrl 'https://localhost:8090' -Token 'token' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'nothing to install'
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { "$Uri" -like '*/pushnotifications' }
    }

    It 'polls the import until it finishes' {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 'n1' } } -ParameterFilter { $Uri -like '*/sampledata/autoinstall' }
        Mock Invoke-RestMethod { [pscustomobject]@{ notifyEvents = [pscustomobject]@{ errorCount = 0; finished = '2026-11-19T00:00:00Z' } } } -ParameterFilter { "$Uri" -like '*/pushnotifications' }

        $null = & $script:SampleDataScript -ApiUrl 'https://localhost:8090' -Token 'token' 6>&1

        $LASTEXITCODE | Should -Be 0
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { "$Uri" -like '*/pushnotifications' }
    }

    It 'sends the install request once: it starts an import, so a retry could start a second one' {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 'n1' } } -ParameterFilter { $Uri -like '*/sampledata/autoinstall' }
        Mock Invoke-RestMethod { [pscustomobject]@{ notifyEvents = [pscustomobject]@{ errorCount = 0; finished = 'x' } } } -ParameterFilter { "$Uri" -like '*/pushnotifications' }

        $null = & $script:SampleDataScript -ApiUrl 'https://localhost:8090' -Token 'token' 6>&1

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*/sampledata/autoinstall' -and -not $MaximumRetryCount }
    }
}
