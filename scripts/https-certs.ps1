# The development certificate of the HTTPS mode (SPEC §10): exported with `dotnet dev-certs`, delivered to the
# containers through the certificates volume (E10), never installed as trust by the scripts (E5).

$script:DevCertificateFileName = 'localhost.pem'
$script:DevCertificateKeyFileName = 'localhost.key'

function Get-MissingDevCertificateFiles {
    # The files of an exported development certificate (localhost.pem, localhost.key) that <Directory> lacks.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Directory
    )

    $missing = $script:DevCertificateFileName, $script:DevCertificateKeyFileName |
        ForEach-Object { Join-Path $Directory $_ } |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
    , [string[]]@($missing)
}

function Export-DevCertificate {
    # Exports the dotnet development certificate as <Destination>/localhost.pem + localhost.key (PEM, no password).
    # $false when dotnet is missing. Throws InvalidOperationException with dotnet's output when the export fails or
    # leaves either file out.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Destination
    )

    if (-not (Get-Command dotnet -CommandType Application -ErrorAction Ignore)) {
        return $false
    }
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $exportPath = Join-Path $Destination $script:DevCertificateFileName
    $output = & dotnet dev-certs https --export-path $exportPath --format PEM --no-password 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new("'dotnet dev-certs https --export-path' failed with exit code ${LASTEXITCODE}: $(ConvertTo-NativeMessage $output 'no output')")
    }
    $missing = Get-MissingDevCertificateFiles $Destination
    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new("'dotnet dev-certs https --export-path' succeeded but did not write $($missing -join ' and '): $(ConvertTo-NativeMessage $output 'no output')")
    }
    $true
}

function Copy-DevCertificateToVolume {
    # Copies the files of SourceDir into dev/ of the named certificates volume, through a short-lived container.
    # A named volume needs no Docker Desktop File Sharing, unlike a bind mount (E10). Throws when Docker fails.
    # The volume is created first, when missing, with the ownership labels Compose puts on its own volumes (R29):
    # otherwise Compose warns "was not created by Docker Compose" on every start and `down -v` skips the volume.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$VolumeName,
        [Parameter(Mandatory, Position = 1)][string]$SourceDir,
        [Parameter(Mandatory, Position = 2)][string]$ProjectName
    )

    $null = & docker volume create --label "com.docker.compose.project=$ProjectName" --label 'com.docker.compose.volume=certs' $VolumeName
    Assert-NativeSuccess "docker volume create for the volume '$VolumeName'"

    # Capture first, check the exit code, then take the first line: `| Select-Object -First 1` stops the pipeline
    # before PowerShell updates $LASTEXITCODE, so the check would read the previous native command's code.
    $createOutput = & docker container create -v "${VolumeName}:/certs" alpine
    $createExitCode = $LASTEXITCODE
    $containerId = ($createOutput | Select-Object -First 1)
    if ($createExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($containerId)) {
        throw [System.InvalidOperationException]::new("docker container create for the volume '$VolumeName' failed with exit code $createExitCode.")
    }
    try {
        $sourcePath = (Resolve-Path -LiteralPath $SourceDir).ProviderPath
        & docker cp "$sourcePath/." "${containerId}:/certs/dev/"
        Assert-NativeSuccess "docker cp of '$SourceDir' into the volume '$VolumeName'"
    }
    finally {
        $null = & docker rm $containerId
    }
}

function Get-DevCertificateFile {
    # The certificate in <Directory>/localhost.pem, or $null when that file or localhost.key is missing, or the
    # certificate cannot be read (a half or damaged export).
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Directory
    )

    if ((Get-MissingDevCertificateFiles $Directory).Count -gt 0) {
        return $null
    }
    try {
        [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
            [System.IO.File]::ReadAllText((Join-Path $Directory $script:DevCertificateFileName)))
    }
    catch [System.Security.Cryptography.CryptographicException] {
        $null
    }
}

# The staging folder of Sync-DevCertificate, under backend/: it holds the private key while start runs, and
# backend/.dockerignore keeps one that a killed start left behind out of the platform image's build context.
$script:DevCertificateStagingPrefix = '.dev-certificate-'

function Sync-DevCertificate {
    # Puts dotnet's current development certificate in <SolutionFolder>/backend/certs and in the certificates volume.
    # It is exported into a staging folder on every run and replaces the files only when its thumbprint differs, so a
    # renewed certificate (expiry, or dotnet dev-certs https --clean) reaches the stack, and a half export is never copied.
    # Without dotnet, or when the export fails, a usable earlier export is kept (with a warning for a failed export).
    # Warns when the certificate in use has expired.
    # Returns $true when it replaced a usable certificate: running containers keep the old one until they restart.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$SolutionFolder,
        [Parameter(Mandatory, Position = 1)][string]$VolumeName,
        [Parameter(Mandatory, Position = 2)][string]$ProjectName
    )

    $certsDirectory = Join-Path (Join-Path $SolutionFolder 'backend') 'certs'
    $inUse = Get-DevCertificateFile $certsDirectory
    $changed = $false
    # Beside backend/certs, with its permissions: the private key never lands in the shared temp folder.
    $staging = Join-Path (Join-Path $SolutionFolder 'backend') "$script:DevCertificateStagingPrefix$([guid]::NewGuid().ToString('N'))"
    try {
        $exportError = $null
        $current = $null
        try {
            if (Export-DevCertificate -Destination $staging) {
                $current = Get-DevCertificateFile $staging
                if ($null -eq $current) {
                    $exportError = "'dotnet dev-certs https --export-path' wrote a certificate that cannot be read."
                }
            }
        }
        catch [System.InvalidOperationException] {
            if ($null -eq $inUse) {
                throw
            }
            $exportError = $_.Exception.Message
        }

        if ($current -and ($null -eq $inUse -or $inUse.Thumbprint -cne $current.Thumbprint)) {
            $null = New-Item -ItemType Directory -Path $certsDirectory -Force
            foreach ($fileName in $script:DevCertificateFileName, $script:DevCertificateKeyFileName) {
                Copy-Item -LiteralPath (Join-Path $staging $fileName) -Destination (Join-Path $certsDirectory $fileName) -Force
            }
            $changed = $null -ne $inUse
            $inUse = $current
        }
        elseif ($null -eq $inUse) {
            throw [System.InvalidOperationException]::new("The development certificate could not be exported into '$certsDirectory'. $exportError Install the .NET SDK, then run: dotnet dev-certs https --export-path '$(Join-Path $certsDirectory $script:DevCertificateFileName)' --format PEM --no-password")
        }
        elseif ($exportError) {
            Write-Warning "The current development certificate could not be exported, so the stack keeps the one in '$certsDirectory': $exportError"
        }
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Ignore
    }

    if ($inUse.NotAfter -lt [datetime]::Now) {
        Write-Warning "The development certificate expired on $($inUse.NotAfter.ToString('yyyy-MM-dd')). Renew it with: dotnet dev-certs https --clean, then dotnet dev-certs https --trust, and run start again."
    }
    Copy-DevCertificateToVolume -VolumeName $VolumeName -SourceDir $certsDirectory -ProjectName $ProjectName
    $changed
}

function Test-DevCertificateTrusted {
    # True when `dotnet dev-certs https --check --trust` finds the certificate trusted. Trust added to the system
    # store by hand is not detected (FC §11), so the instructions offer both routes.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Get-Command dotnet -CommandType Application -ErrorAction Ignore)) {
        return $false
    }
    $null = & dotnet dev-certs https --check --trust 2>&1
    $LASTEXITCODE -eq 0
}

function Get-TrustInstructions {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @(
        'Browsers and tools warn about the development certificate until it is trusted. The scripts never install trust; pick a route:'
        '  1. dotnet dev-certs https --trust'
        '     Windows and macOS. Linux with .NET 9 or later, after: export SSL_CERT_DIR="$HOME/.aspnet/dev-certs/trust:<OpenSSL certificate folder>"'
        '     (dotnet dev-certs https --trust --verbose prints the folder; Ubuntu: /usr/lib/ssl/certs)'
        '  2. Linux system store:'
        '     sudo cp backend/certs/localhost.pem /usr/local/share/ca-certificates/start-local-dev.crt'
        '     sudo update-ca-certificates'
    ) -join [Environment]::NewLine
}

function Get-CertsVolumeName {
    # The certificates volume of a solution folder, named as docker-compose/https.yml names it.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$SolutionFolder
    )

    "$(Get-VolumePrefix -Document $Document -SolutionFolder $SolutionFolder)_certs"
}
