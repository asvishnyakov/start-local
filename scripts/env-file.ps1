# The .env document model: parse a .env file into entries that keep the original text
# (comments, blank lines, inline comments, BOM), so a value can change without the file
# being reformatted. Line endings: the first line terminator is written for every line,
# so a file with mixed endings comes back with uniform ones.
#
# Document: [pscustomobject]@{ Eol; Bom; Entries }
#   Eol     line terminator of the file's first line ("`n" or "`r`n")
#   Bom     $true when the file started with a UTF-8 BOM
#   Entries List of hashtables, one per line:
#     Kind='Pair'  Key, Value (as read, before expansion), Expand (whether Get-EnvTable expands it), Prefix (text
#                  before the value), Suffix (whitespace and inline comment after it), Raw (the line as written)
#     Kind='Raw'   Raw only (comment, blank line, or a line this parser does not read)
#
# The values are read as Docker Compose reads them (scripts/compose-env-value.ps1); this file keeps the lines.
# Known limit: a quoted value spanning several lines is not supported; its unclosed quote is a FormatException.

$script:SecretKeys = 'DB_PASSWORD', 'REDIS_PASSWORD', 'ELASTIC_PASSWORD', 'KIBANA_PASSWORD'

# Compose's keys: a leading digit and brackets are allowed, and "KEY: value" is read like "KEY=value".
$script:EnvKeyPattern = '[A-Za-z0-9_.\[\]-]+'
$script:EnvLinePattern = "^(?<head>\s*(?:export\s+)?(?<key>$($script:EnvKeyPattern))\s*[=:])(?<rest>.*)$"
# The keys the scripts write: ones Compose can also expand as ${KEY}.
$script:EnvWritableKeyPattern = '[A-Za-z_][A-Za-z0-9_.-]*'

function ConvertFrom-EnvLine {
    param([string]$Line)

    $rawEntry = @{ Kind = 'Raw'; Raw = $Line }
    $match = [regex]::Match($Line, $script:EnvLinePattern)
    if (-not $match.Success) {
        return $rawEntry
    }

    $read = Read-ComposeEnvValue $match.Groups['rest'].Value
    if (-not $read.Closed) {
        # Compose rejects it too ("unterminated quoted value"); reading it as an unknown line would hide the key.
        return @{ Kind = 'Invalid'; Key = $match.Groups['key'].Value; Raw = $Line }
    }

    return @{
        Kind   = 'Pair'
        Key    = $match.Groups['key'].Value
        # As read, before expansion: Get-EnvTable expands, so a rewrite of another key keeps this line as written.
        Value  = $read.Value
        Expand = $read.Expand
        Prefix = $match.Groups['head'].Value + $read.Leading
        Suffix = $read.Suffix
        Raw    = $Line
    }
}

function ConvertFrom-EnvText {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)

    # Compare the first char, not StartsWith: culture-aware StartsWith treats U+FEFF as ignorable and matches any text.
    $bom = $Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF
    if ($bom) {
        $Text = $Text.Substring(1)
    }

    $firstBreak = $Text.IndexOf("`n")
    $eol = if ($firstBreak -gt 0 -and $Text[$firstBreak - 1] -eq "`r") { "`r`n" } else { "`n" }

    $entries = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in [regex]::Split($Text, "\r?\n")) {
        $lineNumber++
        $entry = ConvertFrom-EnvLine -Line $line
        if ($entry.Kind -eq 'Invalid') {
            throw [System.FormatException]::new("line ${lineNumber}: the quote of $($entry.Key) is not closed. Close it on the same line (values over several lines are not supported).")
        }
        $entries.Add($entry)
    }

    return [pscustomobject]@{ Eol = $eol; Bom = $bom; Entries = $entries }
}

function ConvertTo-EnvText {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][psobject]$Document)

    $lines = foreach ($entry in $Document.Entries) { $entry.Raw }
    $text = $lines -join $Document.Eol
    if ($Document.Bom) {
        $text = [string][char]0xFEFF + $text
    }
    return $text
}

function Get-EnvTable {
    # Each value as Compose reads it: expanded against the process environment and the keys above it. Throws
    # InvalidOperationException naming the key, never the value (it may be a password), when Compose would reject it.
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][psobject]$Document)

    $table = [ordered]@{}
    foreach ($entry in $Document.Entries) {
        if ($entry.Kind -ne 'Pair') {
            continue
        }
        if (-not $entry.Expand) {
            $table[$entry.Key] = $entry.Value
            continue
        }
        try {
            $table[$entry.Key] = Expand-ComposeEnvValue -Value $entry.Value -Earlier $table
        }
        catch [System.InvalidOperationException] {
            throw [System.InvalidOperationException]::new("$($entry.Key) in .env $($_.Exception.Message)")
        }
    }
    return $table
}

function Get-EnvVariableKeys {
    # The keys whose value references a variable as written: unquoted or double-quoted, with a '$' outside '$$' that a
    # name or '{' follows. Compose keeps any other '$' as written, and a single-quoted value is literal to it.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][psobject]$Document)

    $reference = "\`$(\{|$script:ComposeEnvNamePattern)"
    , [string[]]@($Document.Entries |
            Where-Object { $_.Kind -eq 'Pair' -and $_.Expand -and ([string]$_.Value).Replace('$$', '') -match $reference } |
            ForEach-Object { $_.Key })
}

function Get-EnvValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$Key,
        [Parameter(Position = 2)][string]$Default
    )

    $table = Get-EnvTable -Document $Document
    if ($table.Contains($Key)) {
        return $table[$Key]
    }
    if ($PSBoundParameters.ContainsKey('Default')) {
        return $Default
    }
    return $null
}

function Assert-EnvValueWritable {
    param([string]$Key, [string]$Value)

    if ($Key -notmatch "^$($script:EnvWritableKeyPattern)$") {
        throw [System.ArgumentException]::new("'$Key' is not a valid .env key.", 'Key')
    }
    $problem = if ($Value -match '[\r\n]') { 'a line break' }
    elseif ($Value.Contains('$')) { "'`$' (Compose would expand it)" }
    elseif ($Value.Contains('#')) { "'#' (it can start a comment)" }
    elseif ($Value.Contains('"') -or $Value.Contains("'")) { 'a quote' }
    elseif ($Value -ne $Value.Trim()) { 'leading or trailing whitespace' }
    if ($problem) {
        throw [System.ArgumentException]::new("The value for $Key contains $problem and cannot be stored in .env unchanged. Use a value without it.", 'Value')
    }
}

function Set-EnvValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$Key,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Value
    )

    Assert-EnvValueWritable -Key $Key -Value $Value

    # Compose uses the last occurrence of a duplicated key, so that is the one to change.
    $targetIndex = -1
    for ($index = 0; $index -lt $Document.Entries.Count; $index++) {
        $entry = $Document.Entries[$index]
        if ($entry.Kind -eq 'Pair' -and $entry.Key -eq $Key) {
            $targetIndex = $index
        }
    }

    if ($targetIndex -lt 0) {
        $newEntry = @{ Kind = 'Pair'; Key = $Key; Value = $Value; Expand = $true; Prefix = "$Key="; Suffix = ''; Raw = "$Key=$Value" }
        # Keep the end-of-file newline: the empty last entry is what produces it.
        $last = $Document.Entries.Count - 1
        if ($last -ge 0 -and $Document.Entries[$last].Kind -eq 'Raw' -and $Document.Entries[$last].Raw -eq '') {
            $Document.Entries.Insert($last, $newEntry)
        }
        else {
            $Document.Entries.Add($newEntry)
        }
        return
    }

    # Compose reads "KEY=   # comment" as the value "# comment", so a rewritten line never keeps an inline
    # comment: the comment moves, verbatim, onto its own line above. Quotes are dropped: an accepted value never needs them.
    $target = $Document.Entries[$targetIndex]
    $comment = $target.Suffix.TrimStart()
    if ($comment.StartsWith('#')) {
        $Document.Entries.Insert($targetIndex, @{ Kind = 'Raw'; Raw = $comment.TrimEnd() })
    }
    $target.Value = $Value
    # Written unquoted: an accepted value has no '$', so expanding it changes nothing.
    $target.Expand = $true
    $target.Suffix = ''
    $target.Raw = $target.Prefix + $Value
}

function Remove-EnvKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )

    return $Document.Entries.RemoveAll([Predicate[object]] { param($entry) $entry.Kind -eq 'Pair' -and $entry.Key -eq $Key }) -gt 0
}

function Add-MissingEnvKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][psobject]$Template
    )

    $added = [System.Collections.Generic.List[string]]::new()
    $anchorKey = $null
    foreach ($templateEntry in $Template.Entries) {
        if ($templateEntry.Kind -ne 'Pair') {
            continue
        }
        $key = $templateEntry.Key
        $present = $false
        $anchorIndex = -1
        for ($index = 0; $index -lt $Document.Entries.Count; $index++) {
            $entry = $Document.Entries[$index]
            if ($entry.Kind -ne 'Pair') {
                continue
            }
            if ($entry.Key -eq $key) {
                $present = $true
            }
            if ($null -ne $anchorKey -and $entry.Key -eq $anchorKey) {
                $anchorIndex = $index
            }
        }
        if (-not $present) {
            # After the template's previous key (present by now: it was there or was just added); the first key goes on top.
            $Document.Entries.Insert($anchorIndex + 1, $templateEntry.Clone())
            $added.Add($key)
        }
        $anchorKey = $key
    }
    return , $added.ToArray()
}

function New-RandomPassword {
    # Letters and digits only, so .env and Compose read it the same way. Always holds a lowercase letter, an uppercase
    # letter and a digit: the platform requires both cases (ASP.NET Identity defaults) and SQL Server 3 of 4 classes.
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(8, 128)][int]$Length = 16)

    $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    do {
        $characters = for ($position = 0; $position -lt $Length; $position++) {
            $alphabet[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)]
        }
        $password = -join $characters
    } while ($password -cnotmatch '[a-z]' -or $password -cnotmatch '[A-Z]' -or $password -notmatch '[0-9]')
    return $password
}

function Update-EnvSecrets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string[]]$SecretKeys,
        [Parameter(Position = 2)][scriptblock]$Generator = { New-RandomPassword }
    )

    $filled = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $SecretKeys) {
        if ([string]::IsNullOrEmpty((Get-EnvValue -Document $Document -Key $key))) {
            Set-EnvValue -Document $Document -Key $key -Value ([string](& $Generator))
            $filled.Add($key)
        }
    }
    return , $filled.ToArray()
}

function Read-EnvFile {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    # .NET resolves paths against the process directory, not the PowerShell location, and ignores PSDrives.
    $bytes = [System.IO.File]::ReadAllBytes($PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path))
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    try {
        # Strict decoding: a replaced byte would be written back changed.
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    }
    catch [System.Text.DecoderFallbackException] {
        throw [System.FormatException]::new("$Path is not valid UTF-8 text: $($_.Exception.Message) Save it as UTF-8.", $_.Exception)
    }
    if ($hasBom) {
        $text = [string][char]0xFEFF + $text
    }
    return ConvertFrom-EnvText -Text $text
}

function New-FileForWrite {
    # Creates the file, which must not exist yet, and returns it open for writing. -UnixMode (off Windows): the mode the
    # file has from the moment it exists, less what the umask takes away. Without it the file gets the default mode.
    [CmdletBinding()]
    [OutputType([System.IO.FileStream])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [System.Nullable[System.IO.UnixFileMode]]$UnixMode
    )

    $options = [System.IO.FileStreamOptions]@{ Mode = 'CreateNew'; Access = 'Write' }
    if ($null -ne $UnixMode) {
        $options.UnixCreateMode = $UnixMode
    }
    [System.IO.FileStream]::new($Path, $options)
}

function Write-EnvFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$Path
    )

    # The text carries the BOM character when the file was read with one; the encoder writes it as EF BB BF.
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-EnvText -Document $Document))
    # Through a temporary file next to the file written (the link target, for a symlinked .env), then one rename: a
    # crash mid-write cannot leave .env cut short.
    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    $existing = Get-Item -LiteralPath $fullPath -Force -ErrorAction Ignore
    if ($existing.LinkTarget) {
        # A symlinked .env: the rename goes over its target, so the link stays a link.
        $existing = $existing.ResolveLinkTarget($true)
        $fullPath = $existing.FullName
    }
    # The rename gives .env a new file. Off Windows it keeps the mode the user gave the old one, because .env holds the
    # secrets; a new .env gets the default mode.
    $unixMode = if (-not $IsWindows -and $existing -is [System.IO.FileInfo] -and $existing.Exists) { [System.IO.File]::GetUnixFileMode($fullPath) }
    $temporaryPath = "$fullPath.tmp"
    try {
        # A temporary file that a killed run left behind would keep its own mode: start from none.
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Ignore
        # The mode is set as the file is created, so the secrets are never in a file more readable than .env.
        $stream = New-FileForWrite -Path $temporaryPath -UnixMode $unixMode
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $stream.Dispose()
        }
        if ($null -ne $unixMode) {
            # The umask may have narrowed the mode at creation.
            [System.IO.File]::SetUnixFileMode($temporaryPath, $unixMode)
        }
        [System.IO.File]::Move($temporaryPath, $fullPath, $true)
    }
    catch {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Ignore
        throw
    }
}
