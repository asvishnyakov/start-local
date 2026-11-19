# The Docker platform image is built from vc-docker's official Dockerfile, unchanged, downloaded at build time.

$script:PlatformDockerfileBaseUrl = 'https://raw.githubusercontent.com/VirtoCommerce/vc-docker/feat/net10/linux/platform'

function Save-PlatformDockerfile {
    # Downloads the official Dockerfile and the wait-for-it.sh it copies into <Destination>, the image build context.
    # Throws InvalidOperationException naming the URL when a download fails.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Destination
    )

    $null = New-Item -ItemType Directory -Path $Destination -Force
    foreach ($fileName in 'Dockerfile', 'wait-for-it.sh') {
        Invoke-FileDownload "$script:PlatformDockerfileBaseUrl/$fileName" (Join-Path $Destination $fileName) "vc-docker's $fileName"
    }
}
