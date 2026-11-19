#Requires -Version 7.4
# Runs the Pester tests of one tier: pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier Unit|Compose|All
# Exits 0 only when at least one test ran and nothing failed; any other outcome exits 1.
[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Compose', 'All')][string]$Tier = 'Unit',
    # The folder that holds the tier folders (unit/, compose/). Tests of this runner point it at a scratch folder.
    [string]$Root = $PSScriptRoot
)

$tierPath = if ($Tier -eq 'All') { $Root } else { Join-Path $Root $Tier.ToLowerInvariant() }
if (-not (Test-Path -LiteralPath $tierPath -PathType Container)) {
    Write-Error "The test folder '$tierPath' does not exist."
    exit 1
}

Import-Module Pester -MinimumVersion 5.0

$configuration = New-PesterConfiguration
# The folder is the tier: a test runs in the tier of the folder it is in, whatever its tag says.
$configuration.Run.Path = $tierPath
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'

$result = Invoke-Pester -Configuration $configuration
$failed = $result.FailedCount + $result.FailedBlocksCount + $result.FailedContainersCount
if ($result.PassedCount -eq 0) {
    Write-Error "No test passed in '$tierPath'."
}
exit $(if ($failed -eq 0 -and $result.PassedCount -gt 0) { 0 } else { 1 })
