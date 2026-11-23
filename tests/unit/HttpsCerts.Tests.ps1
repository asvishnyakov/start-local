BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

Describe 'HTTPS certificates' -Tag 'Unit' {
    It 'trust instructions name both routes' {
        $text = Get-TrustInstructions
        $text | Should -BeLike '*dotnet dev-certs https --trust*'
        $text | Should -BeLike '*SSL_CERT_DIR*'
        $text | Should -BeLike '*/usr/local/share/ca-certificates*'
        $text | Should -BeLike '*update-ca-certificates*'
    }

    Context 'Sync-DevCertificate' {
        BeforeAll {
            # A self-signed localhost certificate as the PEM pair `dotnet dev-certs https --format PEM` writes.
            function script:New-TestDevCertificate {
                param([datetimeoffset]$NotAfter = [datetimeoffset]::Now.AddYears(1))
                $rsa = [System.Security.Cryptography.RSA]::Create(2048)
                $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                    'CN=localhost', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $certificate = $request.CreateSelfSigned($NotAfter.AddYears(-1), $NotAfter)
                [pscustomobject]@{ Pem = $certificate.ExportCertificatePem(); Key = $rsa.ExportPkcs8PrivateKeyPem(); Thumbprint = $certificate.Thumbprint }
            }

            function script:Write-TestDevCertificate {
                param([string]$Directory, [psobject]$Certificate)
                $null = New-Item -ItemType Directory -Path $Directory -Force
                Set-Content -LiteralPath (Join-Path $Directory 'localhost.pem') -Value $Certificate.Pem -NoNewline
                Set-Content -LiteralPath (Join-Path $Directory 'localhost.key') -Value $Certificate.Key -NoNewline
            }

            $script:CurrentCertificate = New-TestDevCertificate
            $script:OtherCertificate = New-TestDevCertificate
        }

        BeforeEach {
            $solution = Join-Path $TestDrive "solution-$([guid]::NewGuid().ToString('N'))"
            $certsDirectory = Join-Path (Join-Path $solution 'backend') 'certs'
            $null = New-Item -ItemType Directory -Path $solution -Force
            # dotnet's current development certificate.
            $script:DotnetCertificate = $script:CurrentCertificate
            Mock Export-DevCertificate { Write-TestDevCertificate -Directory $Destination -Certificate $script:DotnetCertificate; $true }
            Mock Copy-DevCertificateToVolume { }
        }

        # The private key is staged inside the solution folder, never in the shared temp folder other users can list.
        It 'exports into a staging folder under backend, never straight into backend/certs' {
            $null = Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl'

            Should -Invoke Export-DevCertificate -Times 1 -Exactly -ParameterFilter {
                $normalized = $Destination -replace '\\', '/'
                $normalized -notlike '*/backend/certs' -and $normalized -like "$($solution -replace '\\', '/')/backend/*"
            }
        }

        # A change is a replaced certificate: containers that served the old one must restart. Without a usable one
        # before, no container served it (HTTP mode, or a first HTTPS start), and up creates them with the new one.
        It 'puts the current certificate in backend/certs: <Label>' -ForEach @(
            @{ Label = 'no file'; Present = 'none'; Changed = $false }
            # A half export (an earlier export that failed midway) is replaced, not copied without its other half.
            @{ Label = 'only localhost.pem'; Present = 'pem'; Changed = $false }
            @{ Label = 'only localhost.key'; Present = 'key'; Changed = $false }
            # dotnet dev-certs https --clean, then a new certificate; or the old one expired and dotnet made a new one.
            @{ Label = 'another certificate'; Present = 'other'; Changed = $true }
        ) {
            switch ($Present) {
                'pem' { $null = New-Item -ItemType File -Path (Join-Path $certsDirectory 'localhost.pem') -Force }
                'key' { $null = New-Item -ItemType File -Path (Join-Path $certsDirectory 'localhost.key') -Force }
                'other' { Write-TestDevCertificate -Directory $certsDirectory -Certificate $script:OtherCertificate }
            }

            Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl' | Should -Be $Changed

            Get-Content -LiteralPath (Join-Path $certsDirectory 'localhost.pem') -Raw | Should -BeExactly $script:CurrentCertificate.Pem
            Get-Content -LiteralPath (Join-Path $certsDirectory 'localhost.key') -Raw | Should -BeExactly $script:CurrentCertificate.Key
            Should -Invoke Copy-DevCertificateToVolume -Times 1 -Exactly -ParameterFilter {
                $VolumeName -eq 'sl_certs' -and $ProjectName -eq 'sl' -and ($SourceDir -replace '\\', '/') -like '*/backend/certs'
            }
        }

        It 'keeps the files and reports no change when they hold the current certificate' {
            Write-TestDevCertificate -Directory $certsDirectory -Certificate $script:CurrentCertificate
            $before = (Get-Item -LiteralPath (Join-Path $certsDirectory 'localhost.pem')).LastWriteTimeUtc

            Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl' | Should -BeFalse

            (Get-Item -LiteralPath (Join-Path $certsDirectory 'localhost.pem')).LastWriteTimeUtc | Should -Be $before
            Should -Invoke Copy-DevCertificateToVolume -Times 1 -Exactly
        }

        It 'leaves no staging folder behind' {
            $script:Staging = $null
            Mock Export-DevCertificate { $script:Staging = $Destination; Write-TestDevCertificate -Directory $Destination -Certificate $script:DotnetCertificate; $true }

            $null = Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl'

            $script:Staging | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $script:Staging | Should -BeFalse
        }

        It 'keeps a complete export when dotnet is missing' {
            Mock Export-DevCertificate { $false }
            Write-TestDevCertificate -Directory $certsDirectory -Certificate $script:OtherCertificate

            Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl' | Should -BeFalse

            Get-Content -LiteralPath (Join-Path $certsDirectory 'localhost.pem') -Raw | Should -BeExactly $script:OtherCertificate.Pem
            Should -Invoke Copy-DevCertificateToVolume -Times 1 -Exactly
        }

        It 'keeps a usable certificate and warns when the export fails (<Label>)' -ForEach @(
            @{ Label = 'dotnet fails'; Export = { throw [System.InvalidOperationException]::new('dev-certs failed') } }
            @{ Label = 'unreadable export'; Export = { Set-Content -LiteralPath (Join-Path $Destination 'localhost.pem') -Value 'garbage' -Force; Set-Content -LiteralPath (Join-Path $Destination 'localhost.key') -Value 'garbage'; $true } }
        ) {
            Mock Export-DevCertificate { $null = New-Item -ItemType Directory -Path $Destination -Force; & $Export }
            Write-TestDevCertificate -Directory $certsDirectory -Certificate $script:OtherCertificate

            Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl' -WarningVariable warnings 3>$null | Should -BeFalse

            "$warnings" | Should -BeLike '*could not be exported*keeps*'
            Get-Content -LiteralPath (Join-Path $certsDirectory 'localhost.pem') -Raw | Should -BeExactly $script:OtherCertificate.Pem
            Should -Invoke Copy-DevCertificateToVolume -Times 1 -Exactly
        }

        It 'throws when the export fails and no usable certificate is there' {
            Mock Export-DevCertificate { throw [System.InvalidOperationException]::new('dev-certs failed') }

            { Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl' } | Should -Throw '*dev-certs failed*'

            Should -Invoke Copy-DevCertificateToVolume -Times 0 -Exactly
        }

        It 'throws and copies nothing when dotnet is missing and the export is incomplete' {
            Mock Export-DevCertificate { $false }

            { Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl' } | Should -Throw '*could not be exported*'

            Should -Invoke Copy-DevCertificateToVolume -Times 0 -Exactly
        }

        It 'warns with the renewal commands when the certificate in use has expired' {
            $script:DotnetCertificate = New-TestDevCertificate -NotAfter ([datetimeoffset]::Now.AddDays(-1))

            $null = Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl' -WarningVariable warnings 3>$null

            $warnings | Should -HaveCount 1
            "$warnings" | Should -BeLike '*expired*dotnet dev-certs https --clean*'
        }

        It 'does not warn about a certificate that is still valid' {
            $null = Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl' -WarningVariable warnings 3>$null

            $warnings | Should -HaveCount 0
        }
    }

    Context 'Export-DevCertificate' {
        BeforeAll {
            # Stands in for `dotnet dev-certs https --export-path <path> ...` as $global:FakeDotnet describes it: writes
            # the files named in Writes next to the export path (found by its option name), prints Output, exits ExitCode.
            function script:dotnet {
                $exportPath = $args[[array]::IndexOf($args, '--export-path') + 1]
                foreach ($fileName in $global:FakeDotnet.Writes) {
                    Set-Content -LiteralPath (Join-Path (Split-Path -Parent $exportPath) $fileName) -Value 'content'
                }
                $global:FakeDotnet.Output
                $global:LASTEXITCODE = $global:FakeDotnet.ExitCode
            }
        }

        AfterAll {
            Remove-Variable -Name FakeDotnet -Scope Global -ErrorAction Ignore
        }

        It 'returns $false when dotnet is not installed' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'dotnet' }

            Export-DevCertificate -Destination (Join-Path $TestDrive 'no-dotnet') | Should -BeFalse
        }

        It 'throws with dotnet''s own output when the export fails' {
            $global:FakeDotnet = @{ Writes = @(); Output = 'A valid HTTPS certificate could not be found.'; ExitCode = 4 }
            Mock Get-Command { [pscustomobject]@{ Name = 'dotnet' } } -ParameterFilter { $Name -eq 'dotnet' }

            { Export-DevCertificate -Destination (Join-Path $TestDrive 'failing') } |
                Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*could not be found*'
        }

        It 'throws naming the missing file when dotnet succeeds but writes only <Written>' -ForEach @(
            # An SDK that names a file differently, or a cleanup racing the export.
            @{ Written = 'localhost.pem'; Missing = 'localhost.key' }
            @{ Written = 'localhost.key'; Missing = 'localhost.pem' }
        ) {
            $global:FakeDotnet = @{ Writes = @($Written); Output = 'exported'; ExitCode = 0 }
            Mock Get-Command { [pscustomobject]@{ Name = 'dotnet' } } -ParameterFilter { $Name -eq 'dotnet' }

            $thrown = { Export-DevCertificate -Destination (Join-Path $TestDrive "half-$([guid]::NewGuid().ToString('N'))") } |
                Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage "*$Missing*" -PassThru
            $thrown.Exception.Message | Should -Not -BeLike "*$Written*"
        }

        It 'returns $true when dotnet writes both files' {
            $global:FakeDotnet = @{ Writes = 'localhost.pem', 'localhost.key'; Output = 'exported'; ExitCode = 0 }
            Mock Get-Command { [pscustomobject]@{ Name = 'dotnet' } } -ParameterFilter { $Name -eq 'dotnet' }

            Export-DevCertificate -Destination (Join-Path $TestDrive 'both') | Should -BeTrue
        }
    }

    Context 'Copy-DevCertificateToVolume' {
        BeforeAll {
            # Pester mocks a command that exists; the shim stands in for the docker CLI.
            function script:docker { }
        }

        BeforeEach {
            $source = Join-Path 'TestDrive:' "certs-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType File -Path (Join-Path $source 'localhost.pem') -Force
            $script:dockerCalls = [System.Collections.Generic.List[string]]::new()
            $script:failingVerb = $null
            Mock docker {
                $script:dockerCalls.Add($args -join ' ')
                $global:LASTEXITCODE = if ($args[0] -eq $script:failingVerb) { 1 } else { 0 }
                if ($args[0] -eq 'container') { 'abc123' }
            }
        }

        It 'creates the volume with the Compose ownership labels, then a container on it, copies into dev/ and removes the container' {
            Copy-DevCertificateToVolume -VolumeName 'sl_certs' -SourceDir $source -ProjectName 'sl'

            $script:dockerCalls.Count | Should -Be 4
            $script:dockerCalls[0] | Should -Be 'volume create --label com.docker.compose.project=sl --label com.docker.compose.volume=certs sl_certs'
            $script:dockerCalls[1] | Should -Be 'container create -v sl_certs:/certs alpine'
            $script:dockerCalls[2] | Should -BeLike 'cp *abc123:/certs/dev/'
            ($script:dockerCalls[2] -replace '\\', '/') | Should -BeLike 'cp */certs-*/. abc123:/certs/dev/'
            $script:dockerCalls[3] | Should -Be 'rm abc123'
        }

        It 'removes the container and throws when the copy fails' {
            $script:failingVerb = 'cp'

            { Copy-DevCertificateToVolume -VolumeName 'sl_certs' -SourceDir $source -ProjectName 'sl' } | Should -Throw '*docker cp*failed*'

            $script:dockerCalls[-1] | Should -Be 'rm abc123'
        }

        It 'throws and runs nothing else when the volume cannot be created' {
            $script:failingVerb = 'volume'

            { Copy-DevCertificateToVolume -VolumeName 'sl_certs' -SourceDir $source -ProjectName 'sl' } | Should -Throw '*docker volume create*failed*'

            $script:dockerCalls.Count | Should -Be 1
        }
    }

    It 'Get-CertsVolumeName is the volume prefix plus _certs' {
        $path = Join-Path 'TestDrive:' "env-$([guid]::NewGuid().ToString('N'))"
        Set-Content -LiteralPath $path -Value @('VOLUME_PREFIX=virto', 'COMPOSE_PROJECT_NAME=other')

        Get-CertsVolumeName -Document (Read-EnvFile -Path $path) -SolutionFolder (Join-Path 'TestDrive:' 'My-Stack') | Should -Be 'virto_certs'
    }
}
