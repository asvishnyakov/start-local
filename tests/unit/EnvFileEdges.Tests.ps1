# Set-EnvValue on the lines a hand-edited .env can hold: duplicated keys, whitespace around the key, an `export ` prefix,
# and keys that cannot be written at all.
BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

Describe 'Set-EnvValue edge cases' -Tag 'Unit' {
    Context 'duplicated key' {
        It 'changes only the last occurrence, the one Compose reads' {
            $document = ConvertFrom-EnvText "A=1`nB=x`nA=2`n"

            Set-EnvValue $document 'A' '3'

            ConvertTo-EnvText $document | Should -BeExactly "A=1`nB=x`nA=3`n"
            Get-EnvValue $document 'A' | Should -BeExactly '3'
        }

        It 'Get-EnvValue reads the last occurrence before any write' {
            Get-EnvValue (ConvertFrom-EnvText "A=1`nA=2`n") 'A' | Should -BeExactly '2'
        }
    }

    Context 'whitespace around the key' {
        It 'finds a key written with spaces around it and keeps the spacing' {
            $document = ConvertFrom-EnvText "  A = 1`n"

            Get-EnvValue $document 'A' | Should -BeExactly '1'
            Set-EnvValue $document 'A' '9'

            ConvertTo-EnvText $document | Should -BeExactly "  A = 9`n"
        }

        It 'finds a key written with a tab before the equals sign' {
            $document = ConvertFrom-EnvText "A`t=1`n"

            Set-EnvValue $document 'A' '9'

            ConvertTo-EnvText $document | Should -BeExactly "A`t=9`n"
        }

        It 'rejects a key with leading or trailing whitespace: <Key>' -TestCases @(
            @{ Key = ' A' }
            @{ Key = 'A ' }
            @{ Key = "A`t" }
        ) {
            $document = ConvertFrom-EnvText "A=1`n"

            { Set-EnvValue $document $Key 'x' } | Should -Throw -ExceptionType ([System.ArgumentException]) -ExpectedMessage '*is not a valid .env key*'
            ConvertTo-EnvText $document | Should -BeExactly "A=1`n"
        }
    }

    Context 'invalid key' {
        It 'rejects <Name> without changing the document' -TestCases @(
            @{ Name = 'a key starting with a digit'; Key = '1A' }
            @{ Name = 'a key with a space inside'; Key = 'A B' }
            @{ Name = 'a key with an equals sign'; Key = 'A=B' }
            @{ Name = 'a key with a dollar sign'; Key = 'A$' }
            @{ Name = 'a key with the export prefix'; Key = 'export A' }
        ) {
            $document = ConvertFrom-EnvText "A=1`n"

            { Set-EnvValue $document $Key 'x' } | Should -Throw -ExceptionType ([System.ArgumentException]) -ExpectedMessage '*is not a valid .env key*'
            ConvertTo-EnvText $document | Should -BeExactly "A=1`n"
        }

        It 'rejects an empty key' {
            $document = ConvertFrom-EnvText "A=1`n"

            { Set-EnvValue $document '' 'x' } | Should -Throw
            ConvertTo-EnvText $document | Should -BeExactly "A=1`n"
        }

        It 'accepts the dots and dashes Compose allows in a key' {
            $document = ConvertFrom-EnvText "A=1`n"

            Set-EnvValue $document 'my.key-1' 'x'

            ConvertTo-EnvText $document | Should -BeExactly "A=1`nmy.key-1=x`n"
        }
    }

    Context 'export prefix' {
        It 'changes an exported key and keeps the prefix' {
            $document = ConvertFrom-EnvText "export A=1`n"

            Set-EnvValue $document 'A' '2'

            ConvertTo-EnvText $document | Should -BeExactly "export A=2`n"
            Get-EnvValue $document 'A' | Should -BeExactly '2'
        }

        It 'keeps the spacing of the prefix and moves the inline comment above' {
            $document = ConvertFrom-EnvText " export  A=1 # why`n"

            Set-EnvValue $document 'A' '2'

            ConvertTo-EnvText $document | Should -BeExactly "# why`n export  A=2`n"
        }

        It 'changes the last of an exported and a plain occurrence' {
            $document = ConvertFrom-EnvText "export A=1`nA=2`n"

            Set-EnvValue $document 'A' '3'

            ConvertTo-EnvText $document | Should -BeExactly "export A=1`nA=3`n"
        }

        It 'does not read a key named export as a prefix' {
            $document = ConvertFrom-EnvText "export=1`n"

            Get-EnvValue $document 'export' | Should -BeExactly '1'
            Set-EnvValue $document 'export' '2'

            ConvertTo-EnvText $document | Should -BeExactly "export=2`n"
        }
    }
}
