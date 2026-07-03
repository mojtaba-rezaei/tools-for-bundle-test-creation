BeforeAll {
    Import-Module "$PSScriptRoot/../CloneRepos.psm1" -Force -DisableNameChecking
}

Describe 'Parse-RepoTable' {
    It 'parses a 3-column table, skipping header, separator, and non-table lines' {
        $tmp = New-TemporaryFile
        @'
# Repos

Some preamble text.

| Repo                | Branch       | Status         |
| ------------------- | ------------ | -------------- |
| integrations-bundle | main         |                |
| order-service       | develop      | Cloned (main)  |

Trailing notes.
'@ | Set-Content $tmp

        $rows = Parse-RepoTable -Path $tmp

        $rows.Count | Should -Be 2
        $rows[0].Repo   | Should -Be 'integrations-bundle'
        $rows[0].Branch | Should -Be 'main'
        $rows[0].Status | Should -Be ''
        $rows[1].Repo   | Should -Be 'order-service'
        $rows[1].Branch | Should -Be 'develop'
        $rows[1].Status | Should -Be 'Cloned (main)'

        Remove-Item $tmp
    }
}

Describe 'Get-StatusBranch' {
    It 'returns the branch from "Cloned (main)"' {
        Get-StatusBranch 'Cloned (main)' | Should -Be 'main'
    }
    It 'returns the branch from "Failed (develop): some error"' {
        Get-StatusBranch 'Failed (develop): boom' | Should -Be 'develop'
    }
    It 'handles branch names with slashes like feature/auth' {
        Get-StatusBranch 'Cloned (feature/auth)' | Should -Be 'feature/auth'
    }
    It 'returns $null for an empty string' {
        Get-StatusBranch '' | Should -BeNullOrEmpty
    }
    It 'returns $null when there are no parentheses' {
        Get-StatusBranch 'Cloned' | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-Action' {
    It 'returns Clone when status is empty' {
        Resolve-Action -Branch 'main' -StatusBranch $null -FolderExists $false | Should -Be 'Clone'
    }
    It 'returns Clone when status branch matches but folder is missing' {
        Resolve-Action -Branch 'main' -StatusBranch 'main' -FolderExists $false | Should -Be 'Clone'
    }
    It 'returns Skip when status branch matches and folder exists' {
        Resolve-Action -Branch 'main' -StatusBranch 'main' -FolderExists $true | Should -Be 'Skip'
    }
    It 'returns Switch when status branch differs and folder exists' {
        Resolve-Action -Branch 'develop' -StatusBranch 'main' -FolderExists $true | Should -Be 'Switch'
    }
    It 'returns Clone when status branch differs and folder is missing' {
        Resolve-Action -Branch 'develop' -StatusBranch 'main' -FolderExists $false | Should -Be 'Clone'
    }
}

Describe 'Sync-Repo - Clone' {
    BeforeEach {
        $script:tmpDest = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmpDest | Out-Null
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:tmpDest -ErrorAction SilentlyContinue
    }

    It 'invokes git clone with the right URL and branch, returns Cloned' {
        Mock -ModuleName CloneRepos git { $global:LASTEXITCODE = 0; 'Cloning into ...' }

        $result = Sync-Repo `
            -Repo 'my-repo' `
            -Branch 'main' `
            -Action 'Clone' `
            -Url 'https://dev.azure.com/Org/Proj/_git/my-repo' `
            -Dest $script:tmpDest

        $result.Result  | Should -Be 'Cloned'
        $result.Repo    | Should -Be 'my-repo'
        $result.Branch  | Should -Be 'main'
        Should -Invoke -ModuleName CloneRepos git -ParameterFilter {
            $args -contains 'clone' -and
            $args -contains '--branch' -and
            $args -contains 'main' -and
            $args -contains 'https://dev.azure.com/Org/Proj/_git/my-repo'
        }
    }
}

Describe 'Sync-Repo - Clone over existing folder' {
    BeforeEach {
        $script:tmpDest = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:tmpDest 'my-repo') | Out-Null
        Set-Content -Path (Join-Path $script:tmpDest 'my-repo/stale.txt') -Value 'old contents'
    }
    AfterEach { Remove-Item -Recurse -Force $script:tmpDest -ErrorAction SilentlyContinue }

    It 'removes the existing target folder before cloning' {
        Mock -ModuleName CloneRepos git { $global:LASTEXITCODE = 0; 'Cloning into ...' }

        $result = Sync-Repo -Repo 'my-repo' -Branch 'main' -Action 'Clone' `
            -Url 'https://dev.azure.com/Org/Proj/_git/my-repo' -Dest $script:tmpDest

        $result.Result | Should -Be 'Cloned'
        # The stale folder (and its sentinel) must be gone: proof the wipe ran before clone.
        Test-Path (Join-Path $script:tmpDest 'my-repo/stale.txt') | Should -BeFalse
        Should -Invoke -ModuleName CloneRepos git -ParameterFilter { $args -contains 'clone' }
    }
}

Describe 'Sync-Repo - Switch' {
    BeforeEach {
        $script:tmpDest = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:tmpDest 'my-repo') | Out-Null
    }
    AfterEach { Remove-Item -Recurse -Force $script:tmpDest -ErrorAction SilentlyContinue }

    It 'runs fetch, checkout, pull and returns Cloned' {
        Mock -ModuleName CloneRepos git { $global:LASTEXITCODE = 0; 'ok' }

        $result = Sync-Repo -Repo 'my-repo' -Branch 'develop' -Action 'Switch' `
            -Url 'https://dev.azure.com/Org/Proj/_git/my-repo' -Dest $script:tmpDest

        $result.Result | Should -Be 'Cloned'
        Should -Invoke -ModuleName CloneRepos git -ParameterFilter { $args -contains 'fetch' }   -Times 1
        Should -Invoke -ModuleName CloneRepos git -ParameterFilter { $args -contains 'checkout' -and $args -contains 'develop' } -Times 1
        Should -Invoke -ModuleName CloneRepos git -ParameterFilter { $args -contains 'pull' }    -Times 1
    }
}

Describe 'Sync-Repo - Skip' {
    It 'does nothing and returns Skipped' {
        Mock -ModuleName CloneRepos git { throw 'git should not have been called' }

        $result = Sync-Repo -Repo 'my-repo' -Branch 'main' -Action 'Skip' `
            -Url 'irrelevant' -Dest 'irrelevant'

        $result.Result | Should -Be 'Skipped'
        Should -Not -Invoke -ModuleName CloneRepos git
    }
}

Describe 'Sync-Repo - Failure' {
    BeforeEach {
        $script:tmpDest = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmpDest | Out-Null
    }
    AfterEach { Remove-Item -Recurse -Force $script:tmpDest -ErrorAction SilentlyContinue }

    It 'returns Failed with the error message when git clone exits non-zero' {
        Mock -ModuleName CloneRepos git {
            $global:LASTEXITCODE = 128
            'fatal: Remote branch nope not found in upstream origin'
        }

        $result = Sync-Repo -Repo 'my-repo' -Branch 'nope' -Action 'Clone' `
            -Url 'https://dev.azure.com/Org/Proj/_git/my-repo' -Dest $script:tmpDest

        $result.Result  | Should -Be 'Failed'
        $result.Message | Should -Be 'fatal: Remote branch nope not found in upstream origin'
        $result.Log     | Should -Match 'Remote branch nope not found'
    }
}

Describe 'Write-RepoTable' {
    It 'updates only Status cells, preserves non-table lines, realigns columns' {
        $tmp = New-TemporaryFile
        @'
# Repos

| Repo  | Branch  | Status |
| ----- | ------- | ------ |
| alpha | main    |        |
| beta  | develop | Cloned (main) |

Trailing line.
'@ | Set-Content $tmp

        $results = @(
            [pscustomobject]@{ Repo = 'alpha'; Branch = 'main';    Result = 'Cloned'; Message = '' }
            [pscustomobject]@{ Repo = 'beta';  Branch = 'develop'; Result = 'Failed'; Message = 'remote not found' }
        )

        Write-RepoTable -Path $tmp -Results $results

        $content = Get-Content $tmp -Raw
        $content | Should -Match '# Repos'
        $content | Should -Match 'Trailing line\.'
        $content | Should -Match '\| alpha\s+\| main\s+\| Cloned \(main\)\s+\|'
        $content | Should -Match '\| beta\s+\| develop\s+\| Failed \(develop\): remote not found\s+\|'

        Remove-Item $tmp
    }
}

Describe 'Write-RepoTable - guards' {
    It 'throws a clear error when the file has no markdown table' {
        $tmp = New-TemporaryFile
        "Just some prose, no table here." | Set-Content $tmp

        { Write-RepoTable -Path $tmp -Results @() } | Should -Throw '*No markdown table found*'

        Remove-Item $tmp
    }
    It 'accepts an empty Results array on a valid table (no-ops)' {
        $tmp = New-TemporaryFile
        @'
| Repo | Branch | Status |
| ---- | ------ | ------ |
| a    | main   |        |
'@ | Set-Content $tmp

        { Write-RepoTable -Path $tmp -Results @() } | Should -Not -Throw

        Remove-Item $tmp
    }
}
