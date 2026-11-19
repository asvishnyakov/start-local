# Renamed to install.ps1 (start-local 2.0): fetches the latest release's install.ps1 and runs it with the same arguments.
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'install.ps1'
Invoke-WebRequest https://github.com/VirtoCommerce/start-local/releases/latest/download/install.ps1 -OutFile $installer
& $installer @args
exit $LASTEXITCODE
