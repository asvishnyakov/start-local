# How Docker Compose reads a value in .env (compose-go's dotenv package), so the scripts read every value as Compose
# does. Checked against Docker Compose 5.7.0: tests/unit/ComposeEnvValue.Tests.ps1 holds its answers, and
# tests/compose/EnvParity.Tests.ps1 compares with the Compose on the machine.
#
# - Double quotes: \a \b \f \n \r \t \v \\ \" \$ are escapes, and \0 with up to three digits becomes \ and the digits:
#   the character when they are three octal digits up to 377, else that text. Any other backslash stays as written.
#   The value ends at the closing quote; text after it is ignored.
# - Single quotes: only \' is an escape, and nothing is expanded.
# - Unquoted: no escapes. Trimmed; a space followed by '#' starts a comment (a tab does not).
# - Unquoted and double-quoted values expand $NAME, ${NAME} and ${NAME<op>word} (:- - :+ + :? ?), and $$ is a literal
#   '$'. A name resolves from the process environment first, then from the keys above it in the file.

$script:ComposeEnvEscapePattern = '\\(?:[abfnrtv$"\\]|0[0-9]{0,3})'
$script:ComposeEnvNamePattern = '[A-Za-z_][A-Za-z0-9_]*'

function Read-ComposeEnvValue {
    # Splits the text after "KEY=" into the value as Compose reads it (escapes decoded, not yet expanded) and the text
    # around it. Returns @{ Closed; Value; Expand; Leading; Suffix }: Closed is $false for an unclosed quote,
    # Expand says whether Expand-ComposeEnvValue applies, Leading and Suffix are the text before and after the value.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)

    $leading = [regex]::Match($Text, '^\s*').Value
    $body = $Text.Substring($leading.Length)

    if ($body.Length -gt 0 -and ($body[0] -eq '"' -or $body[0] -eq "'")) {
        $quote = $body[0]
        $closing = [regex]::Match($body.Substring(1), "^(?:[^$quote\\]|\\.)*$quote")
        if (-not $closing.Success) {
            return @{ Closed = $false }
        }
        $inner = $closing.Value.Substring(0, $closing.Value.Length - 1)
        $value = if ($quote -eq '"') { ConvertFrom-ComposeEnvEscapes $inner } else { $inner.Replace("\'", "'") }
        return @{
            Closed  = $true
            Value   = $value
            Expand  = $quote -eq '"'
            Leading = $leading
            Suffix  = $body.Substring(1 + $closing.Length)
        }
    }

    $comment = [regex]::Match($body, ' +#')
    $valuePart = if ($comment.Success) { $body.Substring(0, $comment.Index) } else { $body }
    $value = $valuePart.Trim()
    if ($value.Length -gt 0) {
        $leadingOut = $leading
        $suffix = [regex]::Match($valuePart, '\s*$').Value + $body.Substring($valuePart.Length)
    }
    else {
        # An empty value keeps its whitespace in Suffix, so a later value is written right after "=".
        $leadingOut = ''
        $suffix = $leading + $body
    }
    @{ Closed = $true; Value = $value; Expand = $true; Leading = $leadingOut; Suffix = $suffix }
}

function ConvertFrom-ComposeEnvEscapes {
    # The escapes of a double-quoted value. \$ becomes $$, which the expansion turns into a literal '$'.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Inner)

    [regex]::Replace($Inner, $script:ComposeEnvEscapePattern, {
            param($escape)
            $sequence = $escape.Value.Substring(1)
            switch -CaseSensitive ($sequence[0]) {
                'a' { [string][char]7 }
                'b' { [string][char]8 }
                'f' { [string][char]12 }
                'n' { "`n" }
                'r' { "`r" }
                't' { "`t" }
                'v' { [string][char]11 }
                '$' { '$$' }
                # compose-go rewrites \0 and up to three digits to \ and the digits, a Go octal escape. It decodes only as
                # three octal digits up to 377; anything else stays as that rewritten text.
                '0' {
                    $digits = $sequence.Substring(1)
                    if ($digits -match '^[0-7]{3}$' -and [System.Convert]::ToInt32($digits, 8) -le 255) {
                        [string][char][System.Convert]::ToInt32($digits, 8)
                    }
                    else {
                        '\' + $digits
                    }
                }
                default { $sequence }
            }
        })
}

function Expand-ComposeEnvValue {
    # Expands the variables of a value as Compose does. -Earlier: the keys above it in the file. Throws
    # InvalidOperationException for an unclosed '${', a '${…}' that is no variable, and ${NAME:?message} or
    # ${NAME?message} when NAME is unset (or empty, with the colon). The message is a predicate without the value (it may
    # be a password); the caller puts the key in front of it.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory, Position = 1)][System.Collections.IDictionary]$Earlier
    )

    # Most values reference nothing: skip the character walk.
    if (-not $Value.Contains('$')) {
        return $Value
    }
    $result = [System.Text.StringBuilder]::new()
    $index = 0
    while ($index -lt $Value.Length) {
        $character = $Value[$index]
        if ($character -ne '$' -or $index + 1 -ge $Value.Length) {
            $null = $result.Append($character)
            $index++
            continue
        }
        $next = $Value[$index + 1]
        if ($next -eq '$') {
            $null = $result.Append('$')
            $index += 2
            continue
        }
        if ($next -eq '{') {
            $end = Find-ComposeEnvBraceEnd -Value $Value -Start ($index + 2)
            if ($end -lt 0) {
                throw [System.InvalidOperationException]::new("has an unclosed '`${'.")
            }
            $null = $result.Append((Resolve-ComposeEnvBraced -Expression $Value.Substring($index + 2, $end - $index - 2) -Earlier $Earlier))
            $index = $end + 1
            continue
        }
        $name = [regex]::Match($Value.Substring($index + 1), "^$script:ComposeEnvNamePattern")
        if (-not $name.Success) {
            $null = $result.Append('$')
            $index++
            continue
        }
        $found = Get-ComposeEnvVariable -Name $name.Value -Earlier $Earlier
        if ($found.Set) {
            $null = $result.Append($found.Value)
        }
        $index += 1 + $name.Length
    }
    $result.ToString()
}

function Find-ComposeEnvBraceEnd {
    # The index of the '}' that closes the '${' before -Start, nested ones skipped; -1 when there is none.
    param([string]$Value, [int]$Start)

    $depth = 1
    for ($index = $Start; $index -lt $Value.Length; $index++) {
        if ($Value[$index] -eq '$' -and $index + 1 -lt $Value.Length -and $Value[$index + 1] -eq '{') {
            $depth++
            $index++
        }
        elseif ($Value[$index] -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $index
            }
        }
    }
    -1
}

function Resolve-ComposeEnvBraced {
    # NAME, or NAME followed by :- - :+ + :? ? and a word that is itself expanded.
    param([string]$Expression, [System.Collections.IDictionary]$Earlier)

    $parts = [regex]::Match($Expression, "^(?<name>$script:ComposeEnvNamePattern)(?:(?<operator>:-|-|:\+|\+|:\?|\?)(?<word>.*))?$", 'Singleline')
    if (-not $parts.Success) {
        throw [System.InvalidOperationException]::new("has a '`${…}' that is not a variable Compose can expand.")
    }
    $name = $parts.Groups['name'].Value
    $found = Get-ComposeEnvVariable -Name $name -Earlier $Earlier
    $operator = $parts.Groups['operator'].Value
    $word = { Expand-ComposeEnvValue -Value $parts.Groups['word'].Value -Earlier $Earlier }
    $required = { throw [System.InvalidOperationException]::new("requires $name to be set: $(& $word)") }
    $isSet = $found.Set
    $isNonEmpty = $found.Set -and $found.Value.Length -gt 0
    switch -CaseSensitive ($operator) {
        '' { if ($isSet) { $found.Value } else { '' } }
        ':-' { if ($isNonEmpty) { $found.Value } else { & $word } }
        '-' { if ($isSet) { $found.Value } else { & $word } }
        ':+' { if ($isNonEmpty) { & $word } else { '' } }
        '+' { if ($isSet) { & $word } else { '' } }
        ':?' { if ($isNonEmpty) { $found.Value } else { & $required } }
        '?' { if ($isSet) { $found.Value } else { & $required } }
    }
}

function Get-ComposeEnvVariable {
    # A name's value as Compose resolves it while reading .env: the process environment first, then the keys above.
    param([string]$Name, [System.Collections.IDictionary]$Earlier)

    $fromProcess = [System.Environment]::GetEnvironmentVariable($Name)
    if ($null -ne $fromProcess) {
        return @{ Set = $true; Value = $fromProcess }
    }
    if ($Earlier.Contains($Name)) {
        return @{ Set = $true; Value = [string]$Earlier[$Name] }
    }
    @{ Set = $false; Value = '' }
}
