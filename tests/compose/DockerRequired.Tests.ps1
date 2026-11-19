# The Compose tier needs the docker CLI. The other files of the tier skip their tests without it (-Skip:(-not $hasDocker)),
# so without this check a runner that lost docker would pass the tier with almost every test skipped.
BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

Describe 'Compose tier prerequisites' -Tag 'Compose' {
    It 'the docker CLI is on PATH (the tier skips nearly every test without it)' {
        # The same predicate the skipping files use.
        $docker = Get-Command docker -ErrorAction SilentlyContinue

        $docker | Should -Not -BeNullOrEmpty -Because 'the Compose tier cannot run without docker; install Docker or run -Tier Unit'
    }
}
