# Helpers for running native commands (docker, dotnet, vc-build, pwsh).

function Assert-NativeSuccess {
    # Throws when the last native command exited non-zero.
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$Description)

    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new("$Description failed with exit code $LASTEXITCODE.")
    }
}

function ConvertTo-NativeMessage {
    # The output of a failed native command (captured with 2>&1) as one line, or -Fallback when it printed nothing.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][object[]]$Output,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Fallback
    )

    $message = (@($Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' ').Trim()
    if ($message) { $message } else { $Fallback }
}

filter Select-NativeStdout {
    # The stdout lines of a native command's output captured with 2>&1: drops what it wrote to stderr (warnings, errors).
    if ($_ -isnot [System.Management.Automation.ErrorRecord]) {
        $_
    }
}

function ConvertTo-CommandLine {
    # Joins arguments into one command line by the Windows rules (CommandLineToArgvW): an argument that is empty or has
    # whitespace or a quote is quoted, " becomes \", and backslashes before a quote are doubled.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments
    )

    $quoted = foreach ($argument in $Arguments) {
        if ($argument -and $argument -notmatch '[\s"]') {
            $argument
            continue
        }
        $escaped = ($argument -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1'
        "`"$escaped`""
    }
    @($quoted) -join ' '
}
