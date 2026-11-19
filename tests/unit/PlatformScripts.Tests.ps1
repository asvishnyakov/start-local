# check-installed-modules.ps1 and setup-sampledata.ps1 run directly, offline, with recorded platform replies.
# Both scripts end with `exit`, so each test reads $LASTEXITCODE and the host output (6>&1).
BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    $script:CheckModulesScript = Join-Path $PSScriptRoot '../../scripts/check-installed-modules.ps1'
    $script:SampleDataScript = Join-Path $PSScriptRoot '../../scripts/setup-sampledata.ps1'

    function script:ConvertTo-ModulesReply {
        # A recorded GET /api/platform/modules reply: one entry per module, as the platform serializes ModuleDescriptor.
        param([object[]]$Modules)
        $entries = foreach ($module in $Modules) {
            [ordered]@{
                id               = $module.Id
                version          = '3.800.0'
                title            = $module.Id
                isInstalled      = $module.IsInstalled
                validationErrors = [string[]]@(if ($module.ValidationErrors) { $module.ValidationErrors })
            }
        }
        ConvertTo-Json -InputObject @($entries) -Depth 4
    }

    function script:ConvertTo-NotificationsReply {
        # A recorded POST /api/platform/pushnotifications reply (PushNotificationSearchResult): NotifyEvents is a list.
        param([int]$ErrorCount, [string]$Finished)
        $finishedJson = if ($Finished) { "`"$Finished`"" } else { 'null' }
        "{`"totalCount`":1,`"newCount`":1,`"notifyEvents`":[{`"id`":`"n1`",`"notifyType`":`"SampleDataImportPushNotification`",`"description`":`"Importing`",`"errorCount`":$ErrorCount,`"finished`":$finishedJson}]}"
    }
}

Describe 'check-installed-modules.ps1' -Tag 'Unit' {
    BeforeEach {
        Mock Watch-Url-Up { $true }
        Mock Get-AdminToken { 'token' }
        Mock Start-Sleep { }
        $global:LASTEXITCODE = 0
    }

    It 'exits 1 when no admin password signs in' {
        Mock Get-AdminToken { $null }
        Mock Invoke-RestMethod { throw 'no request expected' }

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' -AdminPassword 'configured' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'accepts none of the admin passwords'
        Should -Invoke Get-AdminToken -Times 1 -Exactly -ParameterFilter { $AdminPassword -ceq 'configured' }
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'exits 1 when the modules request fails' {
        Mock Invoke-RestMethod { throw 'Response status code does not indicate success: 500 (Internal Server Error).' }

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Failed to check modules status at https://localhost:8090/api/platform/modules'
        $output | Should -Match '500'
    }

    It 'exits 1 for an empty module list' {
        Mock Invoke-RestMethod { '[]' | ConvertFrom-Json }

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'No module info returned'
    }

    It 'exits 1 and prints the errors when a module has validation errors' {
        $reply = ConvertTo-ModulesReply @(
            @{ Id = 'VirtoCommerce.Core'; IsInstalled = $true; ValidationErrors = @() }
            @{ Id = 'VirtoCommerce.Catalog'; IsInstalled = $false; ValidationErrors = @('Dependency VirtoCommerce.Core 3.900.0 is not met.') }
        )
        Mock Invoke-RestMethod { $reply | ConvertFrom-Json }

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' -MinInstalledModules 1 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Module VirtoCommerce.Catalog has validation errors'
        $output | Should -Match 'Dependency VirtoCommerce.Core 3.900.0 is not met'
    }

    It 'exits 1 when fewer modules are installed than required, naming both counts' {
        $reply = ConvertTo-ModulesReply @(
            @{ Id = 'VirtoCommerce.Core'; IsInstalled = $true }
            @{ Id = 'VirtoCommerce.Catalog'; IsInstalled = $true }
            @{ Id = 'VirtoCommerce.Orders'; IsInstalled = $false }
        )
        Mock Invoke-RestMethod { $reply | ConvertFrom-Json }

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' -MinInstalledModules 3 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Modules installed: 2'
        $output | Should -Match 'Expected at least 3 installed modules, found 2'
    }

    It 'counts a one-module reply as one module' {
        $reply = ConvertTo-ModulesReply @(@{ Id = 'VirtoCommerce.Core'; IsInstalled = $true })
        Mock Invoke-RestMethod { $reply | ConvertFrom-Json }

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' -MinInstalledModules 1 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Modules installed: 1'
    }

    It 'passes when enough modules are installed, and passes -SkipCertificateCheck with the bearer token' {
        $reply = ConvertTo-ModulesReply @(
            @{ Id = 'VirtoCommerce.Core'; IsInstalled = $true }
            @{ Id = 'VirtoCommerce.Catalog'; IsInstalled = $true }
        )
        Mock Invoke-RestMethod { $reply | ConvertFrom-Json }

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' -MinInstalledModules 2 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'VirtoCommerce.Catalog version 3.800.0 is installed'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $SkipCertificateCheck -and "$Uri" -ceq 'https://localhost:8090/api/platform/modules' -and $Headers.Authorization -ceq 'Bearer token'
        }
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { -not $SkipCertificateCheck }
    }
}

Describe 'setup-sampledata.ps1' -Tag 'Unit' {
    BeforeEach {
        Mock Get-AdminToken { 'token' }
        Mock Start-Sleep { }
        $global:LASTEXITCODE = 0
    }

    It 'exits 1 when no admin password signs in, without an install request' {
        Mock Get-AdminToken { $null }
        Mock Invoke-RestMethod { throw 'no request expected' }

        $output = & $script:SampleDataScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'accepts none of the admin passwords'
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'exits 1 when the install request fails' {
        Mock Invoke-RestMethod { throw 'Response status code does not indicate success: 401 (Unauthorized).' } -ParameterFilter { "$Uri" -like '*/sampledata/*' }

        $output = & $script:SampleDataScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Failed to start sample data installation at https://localhost:8090/api/platform/sampledata/autoinstall'
        $output | Should -Match '401'
    }

    It 'imports from the given source URL instead of autoinstall' {
        Mock Invoke-RestMethod { $null } -ParameterFilter { "$Uri" -like '*/sampledata/*' }

        $null = & $script:SampleDataScript -ApiUrl 'https://localhost:8090' -SampleDataSrc 'https://example.test/sample.zip' 6>&1

        $LASTEXITCODE | Should -Be 0
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            "$Uri" -ceq 'https://localhost:8090/api/platform/sampledata/import?url=https://example.test/sample.zip'
        }
    }

    It 'exits 1 when the state request fails' {
        Mock Invoke-RestMethod { '{"id":"n1","notifyType":"SampleDataImportPushNotification"}' | ConvertFrom-Json } -ParameterFilter { "$Uri" -like '*/sampledata/*' }
        Mock Invoke-RestMethod { throw 'connection reset' } -ParameterFilter { "$Uri" -like '*/pushnotifications' }

        $output = & $script:SampleDataScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Failed to query sample data installation state'
    }

    It 'exits 1 when the import reports errors (errorCount > 0)' {
        Mock Invoke-RestMethod { '{"id":"n1","notifyType":"SampleDataImportPushNotification"}' | ConvertFrom-Json } -ParameterFilter { "$Uri" -like '*/sampledata/*' }
        $reply = ConvertTo-NotificationsReply -ErrorCount 2
        Mock Invoke-RestMethod { $reply | ConvertFrom-Json } -ParameterFilter { "$Uri" -like '*/pushnotifications' }

        $output = & $script:SampleDataScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Sample data installation failed'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { "$Uri" -like '*/pushnotifications' }
    }

    It 'polls a recorded unfinished reply until it finishes' {
        Mock Invoke-RestMethod { '{"id":"n1","notifyType":"SampleDataImportPushNotification"}' | ConvertFrom-Json } -ParameterFilter { "$Uri" -like '*/sampledata/*' }
        $script:polls = 0
        $running = ConvertTo-NotificationsReply -ErrorCount 0
        $finished = ConvertTo-NotificationsReply -ErrorCount 0 -Finished '2026-11-19T10:00:00Z'
        Mock Invoke-RestMethod {
            $script:polls++
            $(if ($script:polls -lt 3) { $running } else { $finished }) | ConvertFrom-Json
        } -ParameterFilter { "$Uri" -like '*/pushnotifications' }

        $output = & $script:SampleDataScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Sample data installation complete'
        Should -Invoke Invoke-RestMethod -Times 3 -Exactly -ParameterFilter {
            "$Uri" -like '*/pushnotifications' -and ($Body | ConvertFrom-Json).Ids[0] -ceq 'n1'
        }
    }

    It 'exits 1 after 180 polls when the import never finishes' {
        Mock Invoke-RestMethod { '{"id":"n1","notifyType":"SampleDataImportPushNotification"}' | ConvertFrom-Json } -ParameterFilter { "$Uri" -like '*/sampledata/*' }
        $running = ConvertTo-NotificationsReply -ErrorCount 0
        Mock Invoke-RestMethod { $running | ConvertFrom-Json } -ParameterFilter { "$Uri" -like '*/pushnotifications' }

        $output = & $script:SampleDataScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'did not complete within 540 seconds'
        Should -Invoke Invoke-RestMethod -Times 180 -Exactly -ParameterFilter { "$Uri" -like '*/pushnotifications' }
    }

    It 'passes -SkipCertificateCheck on the install and the state requests' {
        Mock Invoke-RestMethod { '{"id":"n1","notifyType":"SampleDataImportPushNotification"}' | ConvertFrom-Json } -ParameterFilter { "$Uri" -like '*/sampledata/*' }
        $finished = ConvertTo-NotificationsReply -ErrorCount 0 -Finished '2026-11-19T10:00:00Z'
        Mock Invoke-RestMethod { $finished | ConvertFrom-Json } -ParameterFilter { "$Uri" -like '*/pushnotifications' }

        $null = & $script:SampleDataScript -ApiUrl 'https://localhost:8090' 6>&1

        $LASTEXITCODE | Should -Be 0
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $SkipCertificateCheck -and "$Uri" -like '*/sampledata/autoinstall' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $SkipCertificateCheck -and "$Uri" -like '*/pushnotifications' }
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { -not $SkipCertificateCheck }
    }
}
