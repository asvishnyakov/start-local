# How the scripts read a .env value: Docker Compose's own rules (compose-go's dotenv). Every expected value below was
# recorded from Docker Compose 5.7.0 (`docker compose config` over an env_file); tests/compose/EnvParity.Tests.ps1
# checks the same file against the Compose on the machine.
BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    function script:Read-Table {
        param([string[]]$Lines)
        Get-EnvTable -Document (ConvertFrom-EnvText ($Lines -join "`n"))
    }
}

Describe 'Compose .env values' -Tag 'Unit' {
    Context 'quotes and escapes' {
        It 'reads <Line> as Compose does' -ForEach @(
            @{ Line = 'K=plain'; Expected = 'plain' }
            # Double quotes: only \a \b \f \n \r \t \v \\ \" \$ and \0 + three octal digits are escapes; any other stays as written.
            @{ Line = 'K="C:\dev\platform"'; Expected = 'C:\dev\platform' }
            @{ Line = 'K="a\x41"'; Expected = 'a\x41' }
            @{ Line = 'K="\0101"'; Expected = 'A' }
            @{ Line = 'K="\c"'; Expected = '\c' }
            @{ Line = 'K="\''"'; Expected = '\''' }
            @{ Line = 'K="a\\b"'; Expected = 'a\b' }
            @{ Line = 'K="tab\tx"'; Expected = "tab`tx" }
            @{ Line = 'K="line\nbreak"'; Expected = "line`nbreak" }
            @{ Line = 'K="a\"b"'; Expected = 'a"b' }
            @{ Line = 'K="cost\$5"'; Expected = 'cost$5' }
            @{ Line = 'K="quoted" trailing'; Expected = 'quoted' }
            # Single quotes: only \' is an escape, and nothing is expanded.
            @{ Line = "K='it\'s'"; Expected = "it's" }
            @{ Line = "K='a\\b'"; Expected = 'a\\b' }
            @{ Line = "K='single `$x \n'"; Expected = 'single $x \n' }
            # Unquoted: no escapes; trimmed; a comment starts at a space before '#', a tab does not start one.
            @{ Line = 'K=\n'; Expected = '\n' }
            @{ Line = 'K=   spaced value   '; Expected = 'spaced value' }
            @{ Line = 'K=a #c'; Expected = 'a' }
            @{ Line = "K=val`t#tab"; Expected = "val`t#tab" }
            @{ Line = 'K=$$x'; Expected = '$x' }
        ) {
            (Read-Table $Line)['K'] | Should -BeExactly $Expected
        }

        It 'reads <Line> under the key <Key>' -ForEach @(
            @{ Line = 'export K20=e'; Key = 'K20'; Expected = 'e' }
            @{ Line = 'K9: yaml'; Key = 'K9'; Expected = 'yaml' }
            @{ Line = '9K=digit'; Key = '9K'; Expected = 'digit' }
        ) {
            (Read-Table $Line)[$Key] | Should -BeExactly $Expected
        }
    }

    Context 'variable expansion' {
        BeforeAll {
            $env:SL_PARITY_ONLY_OS = 'os'
            $env:SL_PARITY_BOTH = 'fromos'
        }

        AfterAll {
            Remove-Item Env:SL_PARITY_ONLY_OS, Env:SL_PARITY_BOTH -ErrorAction Ignore
        }

        It 'expands <Line> as Compose does' -ForEach @(
            @{ Line = 'K=${K1}_x'; Expected = 'plain_x' }
            @{ Line = 'K="$K1"'; Expected = 'plain' }
            @{ Line = 'K=$K1.z'; Expected = 'plain.z' }
            @{ Line = "K='`${K1}'"; Expected = '${K1}' }
            @{ Line = 'K=${UNSET:-def}'; Expected = 'def' }
            @{ Line = 'K=${UNSET-dash}'; Expected = 'dash' }
            @{ Line = 'K=${EMPTY:-colon}'; Expected = 'colon' }
            @{ Line = 'K=${EMPTY-dash}'; Expected = '' }
            @{ Line = 'K="${K1:+set}"'; Expected = 'set' }
            @{ Line = 'K=${UNSET:+set}'; Expected = '' }
            @{ Line = 'K=${K1:?missing}'; Expected = 'plain' }
            @{ Line = 'K=${UNSET:-${K1}}'; Expected = 'plain' }
            @{ Line = 'K=${UNSET}x'; Expected = 'x' }
            @{ Line = 'K=${SL_PARITY_ONLY_OS}_y'; Expected = 'os_y' }
            # The environment of the process comes first, as in Compose.
            @{ Line = 'K=${SL_PARITY_BOTH}_x'; Expected = 'fromos_x' }
        ) {
            (Read-Table 'K1=plain', 'EMPTY=', 'SL_PARITY_BOTH=fromfile', $Line)['K'] | Should -BeExactly $Expected
        }

        It 'fails, naming the variable, on ${VAR:?message} with VAR unset' {
            { Read-Table 'K=${UNSET:?set it first}' } | Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*UNSET*set it first*'
        }

        It 'reads the value itself unexpanded from the document entry, so a rewrite keeps the text as written' {
            $document = ConvertFrom-EnvText "K1=plain`nK=`${K1}_x"
            ConvertTo-EnvText $document | Should -BeExactly "K1=plain`nK=`${K1}_x"
        }
    }
}
