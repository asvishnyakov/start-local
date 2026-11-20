# check-installed-modules.ps1 and setup-sampledata.ps1 run directly, offline, with recorded platform replies.
# Both scripts end with `exit`, so each test reads $LASTEXITCODE and the host output (6>&1).
BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    $script:CheckModulesScript = Join-Path $PSScriptRoot '../../scripts/check-installed-modules.ps1'
    $script:SampleDataScript = Join-Path $PSScriptRoot '../../scripts/setup-sampledata.ps1'

    function script:ConvertTo-SystemInfoReply {
        # A recorded GET /api/platform/diagnostics/systeminfo reply: the installed modules, as the platform serializes them.
        param([string[]]$ModuleIds)
        $entries = foreach ($moduleId in $ModuleIds) { [ordered]@{ id = $moduleId; version = '3.800.0'; isInstalled = $true; validationErrors = [string[]]@() } }
        ConvertTo-Json -InputObject ([ordered]@{ platformVersion = '3.1076.13'; installedModules = @($entries) }) -Depth 4
    }

    function script:ConvertTo-ErrorsReply {
        # A recorded GET /api/platform/diagnostics/errors reply: the installed modules that failed to load.
        param([hashtable[]]$Failed)
        $entries = foreach ($module in $Failed) { [ordered]@{ id = $module.Id; version = '3.800.0'; isInstalled = $true; validationErrors = [string[]]@($module.Errors) } }
        ConvertTo-Json -InputObject @($entries) -Depth 4
    }

    function script:ConvertTo-NotificationsReply {
        # A recorded POST /api/platform/pushnotifications reply (PushNotificationSearchResult): NotifyEvents is a list.
        param([int]$ErrorCount, [string]$Finished)
        $finishedJson = if ($Finished) { "`"$Finished`"" } else { 'null' }
        "{`"totalCount`":1,`"newCount`":1,`"notifyEvents`":[{`"id`":`"n1`",`"notifyType`":`"SampleDataImportPushNotification`",`"description`":`"Importing`",`"errorCount`":$ErrorCount,`"finished`":$finishedJson}]}"
    }
}

# The check reads the platform's diagnostics, which list only what is installed: the modules list (/api/platform/modules)
# also loads the external modules catalog, so it fails offline or behind a TLS-intercepting proxy.
Describe 'check-installed-modules.ps1' -Tag 'Unit' {
    # Globals: the mock bodies run in the scope of the script under test, where this file's $script: variables are unset.
    AfterAll {
        Remove-Variable -Name CheckModulesSystemInfo, CheckModulesErrors, CheckModulesFailingEndpoint -Scope Global -ErrorAction Ignore
    }

    BeforeEach {
        Mock Watch-Url-Up { $true }
        Mock Get-AdminToken { 'token' }
        Mock Start-Sleep { }
        $global:CheckModulesSystemInfo = ConvertTo-SystemInfoReply 'VirtoCommerce.Core', 'VirtoCommerce.Catalog'
        $global:CheckModulesErrors = ConvertTo-ErrorsReply @()
        Mock Invoke-RestMethod { $global:CheckModulesSystemInfo | ConvertFrom-Json } -ParameterFilter { "$Uri" -like '*/api/platform/diagnostics/systeminfo' }
        Mock Invoke-RestMethod { , ($global:CheckModulesErrors | ConvertFrom-Json) } -ParameterFilter { "$Uri" -like '*/api/platform/diagnostics/errors' }
        $global:LASTEXITCODE = 0
    }

    It 'exits 1 when no admin password signs in' {
        Mock Get-AdminToken { $null }

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' -AdminPassword 'configured' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'accepts none of the admin passwords'
        Should -Invoke Get-AdminToken -Times 1 -Exactly -ParameterFilter { $AdminPassword -ceq 'configured' }
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'exits 1 naming the URL when a diagnostics request fails (<Endpoint>)' -ForEach @(
        @{ Endpoint = 'systeminfo' }, @{ Endpoint = 'errors' }
    ) {
        $global:CheckModulesFailingEndpoint = $Endpoint
        Mock Invoke-RestMethod { throw 'Response status code does not indicate success: 500 (Internal Server Error).' } -ParameterFilter { "$Uri" -like "*/api/platform/diagnostics/$global:CheckModulesFailingEndpoint" }

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match "Failed to check modules status at https://localhost:8090/api/platform/diagnostics/$Endpoint"
        $output | Should -Match '500'
    }

    It 'exits 1 when no module is installed' {
        $global:CheckModulesSystemInfo = ConvertTo-SystemInfoReply @()

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'No installed modules'
    }

    It 'exits 1 and prints the errors of every module that failed to load' {
        $global:CheckModulesErrors = ConvertTo-ErrorsReply @(
            @{ Id = 'VirtoCommerce.Catalog'; Errors = @('Module dependency VirtoCommerce.Core 3.900.0 is incompatible with installed 3.800.0') }
            @{ Id = 'VirtoCommerce.Search'; Errors = @("Module skipped because its dependency 'VirtoCommerce.Catalog' has errors") }
        )

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Module VirtoCommerce.Catalog has errors'
        $output | Should -Match 'is incompatible with installed 3.800.0'
        $output | Should -Match 'Module VirtoCommerce.Search has errors'
    }

    It 'passes with a single installed module: there is no minimum count' {
        $global:CheckModulesSystemInfo = ConvertTo-SystemInfoReply 'VirtoCommerce.Core'

        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Modules installed: 1'
    }

    It 'lists the installed modules, reads systeminfo with the bearer token and errors anonymously, and never the modules catalog' {
        $output = & $script:CheckModulesScript -ApiUrl 'https://localhost:8090' 6>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'VirtoCommerce.Catalog version 3.800.0 is installed'
        $output | Should -Match 'Modules installed: 2'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $SkipCertificateCheck -and "$Uri" -ceq 'https://localhost:8090/api/platform/diagnostics/systeminfo' -and $Headers.Authorization -ceq 'Bearer token'
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $SkipCertificateCheck -and "$Uri" -ceq 'https://localhost:8090/api/platform/diagnostics/errors'
        }
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { "$Uri" -like '*/api/platform/modules*' }
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
