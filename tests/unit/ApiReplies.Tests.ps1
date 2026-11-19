# The parsing of platform and GitHub API replies, offline: Invoke-RestMethod and Invoke-WebRequest are mocked with
# recorded replies (JSON text through ConvertFrom-Json, as the real cmdlets hand them back).
BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    # POST /connect/token (OpenIddict), password grant.
    $script:TokenReply = '{"token_type":"Bearer","access_token":"eyJhbGciOiJSUzI1NiJ9.recorded","expires_in":1799,"refresh_token":"CfDJ8recorded"}'
    # A refused password: 400 with SecurityErrorDescriber.LoginFailed().
    $script:RefusedTokenReply = '{"error":"invalid_grant","code":"login_failed","error_description":"Login attempt failed. Please check your credentials."}'
    # POST /api/platform/security/users/admin/resetpassword (an ASP.NET Identity result).
    function script:New-RefusedSignInException {
        # What Invoke-WebRequest throws for that 400 reply (without -SkipHttpErrorCheck).
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
        $response.Content = [System.Net.Http.StringContent]::new($script:RefusedTokenReply)
        [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 400 (Bad Request).', $response)
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
            Mock Invoke-WebRequest { throw (New-RefusedSignInException) }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' | Should -BeNullOrEmpty
        }

        It 'returns null for a 200 reply that carries the invalid_grant body instead of a token' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $script:RefusedTokenReply } }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' | Should -BeNullOrEmpty
        }

        It 'returns null for a reply that is not JSON (a proxy error page)' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '<html><body>502 Bad Gateway</body></html>' } }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' | Should -BeNullOrEmpty
        }

        It 'returns null for an empty access_token' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '{"token_type":"Bearer","access_token":"  "}' } }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' | Should -BeNullOrEmpty
        }

        It 'returns the token as a string' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $script:TokenReply } }

            Get-AuthToken -AppAuthUrl 'https://localhost:8090/connect/token' -Username 'admin' -Password 'x' | Should -BeOfType [string]
        }
    }

    Context 'Get-AdminToken' {
        It 'returns the token of the seeded password after the configured one is refused' {
            Mock Invoke-WebRequest { throw (New-RefusedSignInException) } -ParameterFilter { $Body.password -ceq 'configured' }
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
