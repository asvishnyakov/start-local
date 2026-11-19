BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

Describe 'Save-PlatformDockerfile' -Tag 'Unit' {
    It 'downloads the official vc-docker Dockerfile and wait-for-it.sh into the backend folder' {
        Mock Invoke-WebRequest { }
        $backend = Join-Path $TestDrive 'backend'

        Save-PlatformDockerfile -Destination $backend

        $base = 'https://raw.githubusercontent.com/VirtoCommerce/vc-docker/feat/net10/linux/platform'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq "$base/Dockerfile" -and $OutFile -eq (Join-Path $backend 'Dockerfile') }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq "$base/wait-for-it.sh" -and $OutFile -eq (Join-Path $backend 'wait-for-it.sh') }
    }

    It 'throws naming the URL when a download fails' {
        Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('404 (Not Found)') }

        { Save-PlatformDockerfile -Destination (Join-Path $TestDrive 'b2') } |
            Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*vc-docker/feat/net10/linux/platform/Dockerfile*404*'
    }
}
