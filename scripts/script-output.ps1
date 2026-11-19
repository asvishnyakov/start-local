# Console output shared by the entry scripts.

function Write-ScriptError {
    # Prints "Error: <message>" in red. An unexpected error (not one the scripts raise on purpose: InvalidOperation,
    # Argument or Format) also gets the file and line it happened at, so a bug report can say where.
    [CmdletBinding(DefaultParameterSetName = 'Message')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Message')][string]$Message,
        [Parameter(Mandatory, ParameterSetName = 'Record')][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($PSCmdlet.ParameterSetName -eq 'Message') {
        Write-Host "Error: $Message" -ForegroundColor Red
        return
    }
    $exception = $ErrorRecord.Exception
    Write-Host "Error: $($exception.Message)" -ForegroundColor Red
    $expected = $exception -is [System.InvalidOperationException] -or $exception -is [System.ArgumentException] -or $exception -is [System.FormatException]
    if (-not $expected -and $ErrorRecord.InvocationInfo) {
        Write-Host ("At {0}:{1}" -f $ErrorRecord.InvocationInfo.ScriptName, $ErrorRecord.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
        Write-Host $ErrorRecord.ScriptStackTrace -ForegroundColor DarkGray
    }
}
