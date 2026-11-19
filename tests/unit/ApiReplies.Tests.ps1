# The parsing of platform and GitHub API replies, offline: Invoke-RestMethod and Invoke-WebRequest are mocked with
# recorded replies (JSON text through ConvertFrom-Json, as the real cmdlets hand them back).
BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    # POST /connect/token (OpenIddict), password grant.
    $script:TokenReply = '{"token_type":"Bearer","access_token":"eyJhbGciOiJSUzI1NiJ9.recorded","expires_in":1799,"refresh_token":"CfDJ8recorded"}'
    # A refused password: 400 with SecurityErrorDescriber.LoginFailed().
    $script:RefusedTokenReply = '{"error":"invalid_grant","code":"login_failed","error_description":"Login attempt failed. Please check your credentials."}'
    # POST /api/platform/security/users/admin/resetpassword (an ASP.NET Identity result).
    function script:New-BadRequestError {
        # What Invoke-WebRequest throws for a 400 reply (without -SkipHttpErrorCheck): the HttpResponseException, with the
        # reply body in ErrorDetails. -Body: the reply, a refused password by default.
        param([string]$Body = $script:RefusedTokenReply)
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
        $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 400 (Bad Request).', $response)
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'WebCmdletWebResponseException', 'InvalidOperation', $null)
        $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body)
        $record
    }
    $script:ResetAcceptedReply ='{"succeeded":true,"errors":[]}'
    $script:ResetRefusedReply = '{"succeeded":false,"errors":["Passwords must have at least one non alphanumeric character."]}'
}

Describe 'API replies' -Tag 'Unit' {
    Context 'Get-AuthToken' {
        It 'returns the access token of a recorded token reply, sending the password grant' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $script:TokenReply } }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'p4ss' |
                Should -BeExactly 'eyJhbGciOiJSUzI1NiJ9.recorded'

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -ceq 'https://localhost:8090/connect/token' -and $Method -eq 'Post' -and
                $ContentType -ceq 'application/x-www-form-urlencoded' -and
                $Body.grant_type -ceq 'password' -and $Body.username -ceq 'admin' -and $Body.password -ceq 'p4ss'
            }
        }

        It 'passes -SkipCertificateCheck: the platform serves the development certificate' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $script:TokenReply } }

            $null = Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'p4ss'

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $SkipCertificateCheck }
            Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { -not $SkipCertificateCheck }
        }

        It 'returns null for a refused password (Invoke-WebRequest throws on the 400 invalid_grant reply)' {
            Mock Invoke-WebRequest { throw (New-BadRequestError) }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' | Should -BeNullOrEmpty
        }

        It 'treats a refused password quietly: no warning, the caller tries the next candidate' {
            Mock Invoke-WebRequest { throw (New-BadRequestError) }

            $null = Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' -WarningVariable warnings -WarningAction SilentlyContinue

            @($warnings).Count | Should -Be 0
        }

        It 'treats invalid_grant without the platform''s code quietly too (another OpenIddict server)' {
            Mock Invoke-WebRequest { throw (New-BadRequestError -Body '{"error":"invalid_grant"}') }

            $null = Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' -WarningVariable warnings -WarningAction SilentlyContinue

            @($warnings).Count | Should -Be 0
        }

        It 'writes the platform''s reason for a refused password to the verbose stream' {
            Mock Invoke-WebRequest { throw (New-BadRequestError) }

            $verbose = Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' -Verbose 4>&1

            ($verbose -join "`n") | Should -Match 'Login attempt failed'
        }

        It 'warns, with the platform''s reason, for a sign-in refused for another cause than the password (<Code>)' -ForEach @(
            # SecurityErrorDescriber: these are invalid_grant too, and no other password would get in.
            @{ Code = 'user_is_temporary_locked_out'; Description = 'Your account has been temporarily locked. Please try again after some time.' }
            @{ Code = 'password_expired'; Description = 'Your password has been expired and must be changed.' }
        ) {
            $refusedReply = "{`"error`":`"invalid_grant`",`"code`":`"$Code`",`"error_description`":`"$Description`"}"
            Mock Invoke-WebRequest { throw (New-BadRequestError -Body $refusedReply) }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' -WarningVariable warnings -WarningAction SilentlyContinue |
                Should -BeNullOrEmpty

            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*$Code*$Description"
        }

        It 'warns, naming the OAuth error and its description, for a 400 that is not a refused password (<OAuthError>)' -ForEach @(
            @{ OAuthError = 'unsupported_grant_type'; Description = 'The specified grant type is not supported.' }
            @{ OAuthError = 'invalid_client'; Description = 'The client application was not found in the database.' }
        ) {
            $tokenErrorReply = "{`"error`":`"$OAuthError`",`"error_description`":`"$Description`"}"
            Mock Invoke-WebRequest { throw (New-BadRequestError -Body $tokenErrorReply) }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' -WarningVariable warnings -WarningAction SilentlyContinue |
                Should -BeNullOrEmpty

            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*$OAuthError*$Description"
        }

        It 'warns for a 400 that is not an OAuth reply, instead of blaming the password: <Label>' -ForEach @(
            @{ Label = 'a proxy error page'; ReplyBody = '<html><body>400 Bad Request</body></html>'; Expected = '*status 400*400 Bad Request*' }
            @{ Label = 'no body'; ReplyBody = ''; Expected = '*status 400*no body*' }
            @{ Label = 'JSON that is not an object'; ReplyBody = '"oops"'; Expected = '*status 400*JSON that is not a token reply' }
            # ConvertFrom-Json refuses keys that differ only in case; that must not end start.
            @{ Label = 'keys that differ only in case'; ReplyBody = '{"error":"invalid_grant","Error":"x"}'; Expected = '*status 400*JSON that is not a token reply' }
        ) {
            # Not $Body: inside the mock that is Invoke-WebRequest's own parameter.
            Mock Invoke-WebRequest { throw (New-BadRequestError -Body $ReplyBody) }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' -WarningVariable warnings -WarningAction SilentlyContinue |
                Should -BeNullOrEmpty

            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike $Expected
        }

        It 'never prints the values of a JSON reply, which may be tokens: <Label>' -ForEach @(
            @{ Label = 'a 200 with other tokens but no access_token'; Status = 200; Reply = '{"token_type":"Bearer","refresh_token":"CfDJ8-secret-refresh","id_token":"eyJ-secret-id"}'; Expected = '*the keys token_type, refresh_token, id_token' }
            @{ Label = 'a 400 that ConvertFrom-Json cannot read'; Status = 400; Reply = '{"refresh_token":"CfDJ8-secret-refresh","Refresh_Token":"eyJ-secret-id"}'; Expected = '*JSON that is not a token reply' }
            @{ Label = 'a 200 that is a JSON array'; Status = 200; Reply = '["CfDJ8-secret-refresh","eyJ-secret-id"]'; Expected = '*JSON that is not a token reply' }
        ) {
            if ($Status -eq 200) {
                Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $Reply } }
            }
            else {
                Mock Invoke-WebRequest { throw (New-BadRequestError -Body $Reply) }
            }

            $null = Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' -WarningVariable warnings -WarningAction SilentlyContinue

            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike $Expected
            "$($warnings[0])" | Should -Not -Match 'secret'
        }

        It 'shortens a long reply that is not an OAuth reply in its warning' {
            $longBody = '<html>' + ('x' * 5000) + '</html>'
            Mock Invoke-WebRequest { throw (New-BadRequestError -Body $longBody) }

            $null = Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' -WarningVariable warnings -WarningAction SilentlyContinue

            @($warnings).Count | Should -Be 1
            "$($warnings[0])".Length | Should -BeLessThan 500
        }

        It 'warns for a 200 reply without a token whose error is not a refused password' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '{"error":"server_error"}' } }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' -WarningVariable warnings -WarningAction SilentlyContinue |
                Should -BeNullOrEmpty

            ($warnings -join "`n") | Should -Match 'server_error'
        }

        It 'returns null, quietly, for a 200 reply that carries the invalid_grant body instead of a token' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $script:RefusedTokenReply } }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' -WarningVariable warnings -WarningAction SilentlyContinue |
                Should -BeNullOrEmpty

            @($warnings).Count | Should -Be 0
        }

        It 'returns null and warns for a 200 reply with no token and no OAuth error: <Label>' -ForEach @(
            # The same rule as for a 400: only invalid_grant is a refused password.
            @{ Label = 'a proxy page'; Content = '<html><body>502 Bad Gateway</body></html>'; Expected = '*status 200*502 Bad Gateway*' }
            @{ Label = 'an empty access_token'; Content = '{"token_type":"Bearer","access_token":"  "}'; Expected = '*status 200*a JSON object with the keys token_type, access_token' }
            @{ Label = 'an empty object'; Content = '{}'; Expected = '*status 200*a JSON object with no keys' }
            @{ Label = 'no body'; Content = ''; Expected = '*status 200*no body*' }
        ) {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $Content } }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' -WarningVariable warnings -WarningAction SilentlyContinue |
                Should -BeNullOrEmpty

            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike $Expected
        }

        It 'returns the token as a string' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $script:TokenReply } }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' | Should -BeOfType [string]
        }
    }

    Context 'Get-AdminToken' {
        It 'returns the token of the seeded password after the configured one is refused' {
            Mock Invoke-WebRequest { throw (New-BadRequestError) } -ParameterFilter { $Body.password -ceq 'configured' }
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $script:TokenReply } } -ParameterFilter { $Body.password -ceq 'store' }

            Get-AdminToken -ApiUrl 'https://localhost:8090' -AdminPassword 'configured' | Should -BeExactly 'eyJhbGciOiJSUzI1NiJ9.recorded'

            Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $SkipCertificateCheck -and $Uri -ceq 'https://localhost:8090/connect/token' }
        }
    }

    Context 'Set-AdminPassword' {
        It 'returns true for a recorded accepted reply and passes -SkipCertificateCheck' {
            Mock Invoke-RestMethod { $script:ResetAcceptedReply | ConvertFrom-Json }

            Set-AdminPassword -ApiUrl 'https://localhost:8090' -Token 'tok' -NewPassword 'n3w' | Should -BeTrue

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $SkipCertificateCheck }
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { -not $SkipCertificateCheck }
        }

        It 'returns false for a recorded refused reply and warns with the platform errors' {
            Mock Invoke-RestMethod { $script:ResetRefusedReply | ConvertFrom-Json }
            Mock Write-Warning { }

            Set-AdminPassword -ApiUrl 'https://localhost:8090' -Token 'tok' -NewPassword 'weak' | Should -BeFalse

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*non alphanumeric*' }
        }

        It 'returns false for a reply without succeeded (an empty 200)' {
            Mock Invoke-RestMethod { $null }
            Mock Write-Warning { }

            Set-AdminPassword -ApiUrl 'https://localhost:8090' -Token 'tok' -NewPassword 'n3w' | Should -BeFalse
        }
    }

    Context 'ConvertFrom-JsonResponse' {
        It 'parses a reply that came back as text (raw.githubusercontent.com serves text/plain)' {
            $parsed = ConvertFrom-JsonResponse '{"16":"https://example.test/v16/package.json"}'

            $parsed.'16' | Should -BeExactly 'https://example.test/v16/package.json'
        }

        It 'passes an already parsed reply through unchanged' {
            $reply = [pscustomobject]@{ latest = 'https://example.test/latest/package.json' }

            ConvertFrom-JsonResponse $reply | Should -Be $reply
        }
    }

    Context 'Get-BundleFrontendUrl' {
        BeforeAll {
            $script:StableJson = '{"16":"https://raw.githubusercontent.com/VirtoCommerce/vc-modules/master/bundles/v16/package.json","latest":"https://raw.githubusercontent.com/VirtoCommerce/vc-modules/master/bundles/latest/package.json"}' | ConvertFrom-Json
        }

        It 'reads ThemeB2BVue from the package.json of the bundle, served as text' {
            Mock Invoke-RestMethod {
                '{"VirtoCommerce.Core":"3.800.0","ThemeB2BVue":"https://github.com/VirtoCommerce/vc-frontend/releases/download/2.20.0/vc-theme-b2b-vue-2.20.0.zip"}'
            } -ParameterFilter { $Uri -ceq 'https://raw.githubusercontent.com/VirtoCommerce/vc-modules/master/bundles/v16/package.json' }

            Get-BundleFrontendUrl -BundleKey '16' -StableJson $script:StableJson |
                Should -BeExactly 'https://github.com/VirtoCommerce/vc-frontend/releases/download/2.20.0/vc-theme-b2b-vue-2.20.0.zip'
        }

        It 'reads ThemeB2BVue from a package.json served as JSON' {
            Mock Invoke-RestMethod { '{"ThemeB2BVue":"https://example.test/theme.zip"}' | ConvertFrom-Json }

            Get-BundleFrontendUrl -BundleKey 'latest' -StableJson $script:StableJson | Should -BeExactly 'https://example.test/theme.zip'
        }

        It 'throws, naming the key, for a bundle stable.json does not list, without a request' {
            Mock Invoke-RestMethod { throw 'no request expected' }

            { Get-BundleFrontendUrl -BundleKey '99' -StableJson $script:StableJson } | Should -Throw "*Bundle '99' is not listed*"

            Should -Invoke Invoke-RestMethod -Times 0
        }

        It 'throws when the package.json of the bundle has no ThemeB2BVue' {
            Mock Invoke-RestMethod { '{"VirtoCommerce.Core":"3.800.0"}' }

            { Get-BundleFrontendUrl -BundleKey '16' -StableJson $script:StableJson } | Should -Throw "*Bundle '16' has no ThemeB2BVue*"
        }
    }

    Context 'Get-LatestFrontendReleaseUrl' {
        It 'picks the first .zip asset of the release, skipping other assets' {
            Mock Invoke-RestMethod {
                @'
{"tag_name":"2.21.0","assets":[
  {"name":"checksums.txt","browser_download_url":"https://example.test/checksums.txt"},
  {"name":"vc-theme-b2b-vue-2.21.0.zip","browser_download_url":"https://example.test/vc-theme-b2b-vue-2.21.0.zip"},
  {"name":"vc-theme-b2b-vue-2.21.0-sources.zip","browser_download_url":"https://example.test/sources.zip"}
]}
'@ | ConvertFrom-Json
            }

            Get-LatestFrontendReleaseUrl | Should -BeExactly 'https://example.test/vc-theme-b2b-vue-2.21.0.zip'
        }

        It 'throws when the release has no .zip asset' {
            Mock Invoke-RestMethod { '{"tag_name":"2.21.0","assets":[{"name":"notes.md","browser_download_url":"https://example.test/notes.md"}]}' | ConvertFrom-Json }

            { Get-LatestFrontendReleaseUrl } | Should -Throw '*no .zip asset*'
        }

        It 'throws when the release has no assets at all' {
            Mock Invoke-RestMethod { '{"tag_name":"2.21.0","assets":[]}' | ConvertFrom-Json }

            { Get-LatestFrontendReleaseUrl } | Should -Throw '*no .zip asset*'
        }
    }
}
