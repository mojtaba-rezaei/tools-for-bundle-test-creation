# Clone Repos Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a PowerShell 7 script that clones/syncs a list of Azure DevOps repos defined in a markdown table, in parallel, and writes per-row status back into the same file.

**Architecture:** Five pure-ish functions live in a `CloneRepos.psm1` module (parse table → resolve action → run git → write table). A thin `clone-repos.ps1` script handles arg parsing and the parallel fan-out. Pester provides unit tests; the four pure functions are tested directly, and `Sync-Repo` is tested by mocking the `git` command.

**Tech Stack:** PowerShell 7 (`pwsh`), Pester 5, `git` CLI, Azure DevOps HTTPS clone URLs.

## File Structure

| File | Responsibility |
|---|---|
| `clone-repos.ps1` | Entry point. Parameter block, loads module, runs parallel fan-out, writes file, prints summary, sets exit code. |
| `CloneRepos.psm1` | Module exporting `Parse-RepoTable`, `Get-StatusBranch`, `Resolve-Action`, `Sync-Repo`, `Write-RepoTable`. |
| `tests/CloneRepos.Tests.ps1` | Pester tests covering all five functions. |
| `repos.example.md` | Tiny example input file showing the table format. |
| `README.md` | One-page usage doc (only if user wants — skip otherwise). |

---

## Task 0: Verify environment

**Files:** none

- [ ] **Step 1: Check PowerShell 7+**

Run: `pwsh -v`
Expected: output starts with `PowerShell 7.` — if not, install with `winget install Microsoft.PowerShell`.

- [ ] **Step 2: Check git**

Run: `git --version`
Expected: any `git version 2.x` output.

- [ ] **Step 3: Install Pester 5 if missing**

Run: `pwsh -Command "Get-Module Pester -ListAvailable | Select-Object Version"`
If no `5.x` row, install: `pwsh -Command "Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck"`

- [ ] **Step 4: Initialize git repo if needed**

Run: `git rev-parse --is-inside-work-tree 2>/dev/null || git init`
Expected: either `true` (already a repo) or `Initialized empty Git repository...`.

- [ ] **Step 5: Add a minimal `.gitignore`**

Create `.gitignore`:

```
# Smoke-test scratch
_smoke_dest/
repos.smoke.md

# OS
Thumbs.db
.DS_Store
```

- [ ] **Step 6: Commit the design doc, plan, and .gitignore**

```bash
git add .gitignore docs/
git commit -m "chore: initialize repo with design doc and plan"
```

---

## Task 1: Module skeleton + `Parse-RepoTable`

**Files:**
- Create: `CloneRepos.psm1`
- Create: `tests/CloneRepos.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/CloneRepos.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -Command "Invoke-Pester tests/CloneRepos.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Parse-RepoTable` not recognized / module not found.

- [ ] **Step 3: Create the module with `Parse-RepoTable`**

Create `CloneRepos.psm1`:

```powershell
function Parse-RepoTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $lines = Get-Content -LiteralPath $Path
    $rows = New-Object System.Collections.Generic.List[object]
    $sawHeader = $false
    $sawSeparator = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line.TrimStart().StartsWith('|')) { continue }

        if (-not $sawHeader)    { $sawHeader = $true;    continue }
        if (-not $sawSeparator) { $sawSeparator = $true; continue }

        $cells = $line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
        if ($cells.Count -lt 3) { continue }

        $rows.Add([pscustomobject]@{
            Repo       = $cells[0]
            Branch     = $cells[1]
            Status     = $cells[2]
            LineNumber = $i
        })
    }
    return ,$rows.ToArray()
}

Export-ModuleMember -Function Parse-RepoTable
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -Command "Invoke-Pester tests/CloneRepos.Tests.ps1 -Output Detailed"`
Expected: PASS — 1 test passing.

- [ ] **Step 5: Commit**

```bash
git add CloneRepos.psm1 tests/CloneRepos.Tests.ps1
git commit -m "feat: add Parse-RepoTable to read markdown repo table"
```

---

## Task 2: `Get-StatusBranch`

**Files:**
- Modify: `CloneRepos.psm1`
- Modify: `tests/CloneRepos.Tests.ps1`

- [ ] **Step 1: Add failing tests**

Append to `tests/CloneRepos.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `pwsh -Command "Invoke-Pester tests/CloneRepos.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-StatusBranch` not recognized.

- [ ] **Step 3: Implement `Get-StatusBranch`**

Edit `CloneRepos.psm1`. Add this function above `Export-ModuleMember`:

```powershell
function Get-StatusBranch {
    [CmdletBinding()]
    param([Parameter(Position=0)][AllowNull()][AllowEmptyString()][string]$Status)

    if ([string]::IsNullOrWhiteSpace($Status)) { return $null }
    $match = [regex]::Match($Status, '\(([^)]+)\)')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}
```

Update the export line:

```powershell
Export-ModuleMember -Function Parse-RepoTable, Get-StatusBranch
```

- [ ] **Step 4: Run tests**

Run: `pwsh -Command "Invoke-Pester tests/CloneRepos.Tests.ps1 -Output Detailed"`
Expected: PASS — 6 tests passing.

- [ ] **Step 5: Commit**

```bash
git add CloneRepos.psm1 tests/CloneRepos.Tests.ps1
git commit -m "feat: add Get-StatusBranch to parse status parenthetical"
```

---

## Task 3: `Resolve-Action`

**Files:**
- Modify: `CloneRepos.psm1`
- Modify: `tests/CloneRepos.Tests.ps1`

- [ ] **Step 1: Add failing tests covering every decision-matrix row**

Append to `tests/CloneRepos.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -Command "Invoke-Pester tests/CloneRepos.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Resolve-Action` not recognized.

- [ ] **Step 3: Implement `Resolve-Action`**

Add to `CloneRepos.psm1`:

```powershell
function Resolve-Action {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Branch,
        [AllowNull()][AllowEmptyString()][string]$StatusBranch,
        [Parameter(Mandatory)][bool]$FolderExists
    )

    if (-not $FolderExists) { return 'Clone' }
    if ([string]::IsNullOrWhiteSpace($StatusBranch)) { return 'Clone' }
    if ($StatusBranch -eq $Branch) { return 'Skip' }
    return 'Switch'
}
```

Update the export:

```powershell
Export-ModuleMember -Function Parse-RepoTable, Get-StatusBranch, Resolve-Action
```

- [ ] **Step 4: Run tests**

Run: `pwsh -Command "Invoke-Pester tests/CloneRepos.Tests.ps1 -Output Detailed"`
Expected: PASS — 11 tests passing.

- [ ] **Step 5: Commit**

```bash
git add CloneRepos.psm1 tests/CloneRepos.Tests.ps1
git commit -m "feat: add Resolve-Action to pick clone/skip/switch per row"
```

---

## Task 4: `Sync-Repo` — Clone action with mocked git

**Files:**
- Modify: `CloneRepos.psm1`
- Modify: `tests/CloneRepos.Tests.ps1`

- [ ] **Step 1: Add failing test**

Append to `tests/CloneRepos.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run tests to verify it fails**

Run: `pwsh -Command "Invoke-Pester tests/CloneRepos.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Sync-Repo` not recognized.

- [ ] **Step 3: Implement `Sync-Repo` (Clone branch only for now)**

Add to `CloneRepos.psm1`:

```powershell
function Sync-Repo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][ValidateSet('Clone','Switch','Skip')][string]$Action,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest
    )

    $logLines = New-Object System.Collections.Generic.List[string]
    $target = Join-Path $Dest $Repo

    try {
        switch ($Action) {
            'Skip' {
                return [pscustomobject]@{
                    Repo = $Repo; Branch = $Branch; Result = 'Skipped'
                    Message = ''; Log = ''
                }
            }
            'Clone' {
                $out = git clone --branch $Branch $Url $target 2>&1
                $logLines.Add(($out | Out-String).TrimEnd())
                if ($LASTEXITCODE -ne 0) { throw "git clone exited $LASTEXITCODE" }
            }
            'Switch' {
                Push-Location $target
                try {
                    $out = git fetch 2>&1
                    $logLines.Add(($out | Out-String).TrimEnd())
                    if ($LASTEXITCODE -ne 0) { throw "git fetch exited $LASTEXITCODE" }

                    $out = git checkout $Branch 2>&1
                    $logLines.Add(($out | Out-String).TrimEnd())
                    if ($LASTEXITCODE -ne 0) { throw "git checkout exited $LASTEXITCODE" }

                    $out = git pull --ff-only 2>&1
                    $logLines.Add(($out | Out-String).TrimEnd())
                    if ($LASTEXITCODE -ne 0) { throw "git pull exited $LASTEXITCODE" }
                } finally { Pop-Location }
            }
        }
        return [pscustomobject]@{
            Repo = $Repo; Branch = $Branch; Result = 'Cloned'
            Message = ''; Log = ($logLines -join "`n")
        }
    } catch {
        $reason = ($_.Exception.Message -split "`n")[0].Trim()
        return [pscustomobject]@{
            Repo = $Repo; Branch = $Branch; Result = 'Failed'
            Message = $reason; Log = ($logLines -join "`n")
        }
    }
}
```

Update the export:

```powershell
Export-ModuleMember -Function Parse-RepoTable, Get-StatusBranch, Resolve-Action, Sync-Repo
```

- [ ] **Step 4: Run tests**

Run: `pwsh -Command "Invoke-Pester tests/CloneRepos.Tests.ps1 -Output Detailed"`
Expected: PASS — 12 tests passing.

- [ ] **Step 5: Commit**

```bash
git add CloneRepos.psm1 tests/CloneRepos.Tests.ps1
git commit -m "feat: add Sync-Repo Clone action"
```

---

## Task 5: `Sync-Repo` — Switch and Skip actions, plus failure path

**Files:**
- Modify: `tests/CloneRepos.Tests.ps1`

The Switch/Skip code is already implemented in Task 4; this task adds the remaining tests to lock in behavior.

- [ ] **Step 1: Add failing tests**

Append to `tests/CloneRepos.Tests.ps1`:

```powershell
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
        $result.Message | Should -Match 'exited 128'
        $result.Log     | Should -Match 'Remote branch nope not found'
    }
}
```

- [ ] **Step 2: Run tests**

Run: `pwsh -Command "Invoke-Pester tests/CloneRepos.Tests.ps1 -Output Detailed"`
Expected: PASS — 15 tests passing.

- [ ] **Step 3: Commit**

```bash
git add tests/CloneRepos.Tests.ps1
git commit -m "test: cover Sync-Repo Switch, Skip, and Failed paths"
```

---

## Task 6: `Write-RepoTable`

**Files:**
- Modify: `CloneRepos.psm1`
- Modify: `tests/CloneRepos.Tests.ps1`

- [ ] **Step 1: Add failing test**

Append to `tests/CloneRepos.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -Command "Invoke-Pester tests/CloneRepos.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Write-RepoTable` not recognized.

- [ ] **Step 3: Implement `Write-RepoTable`**

Add to `CloneRepos.psm1`:

```powershell
function Write-RepoTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Results
    )

    $resultsByRepo = @{}
    foreach ($r in $Results) { $resultsByRepo[$r.Repo] = $r }

    $lines = Get-Content -LiteralPath $Path
    $rows = Parse-RepoTable -Path $Path

    $newStatusByLine = @{}
    foreach ($row in $rows) {
        $res = $resultsByRepo[$row.Repo]
        if ($null -eq $res) { $newStatusByLine[$row.LineNumber] = $row.Status; continue }
        $newStatus = switch ($res.Result) {
            'Cloned'  { "Cloned ($($row.Branch))" }
            'Skipped' { $row.Status }
            'Failed'  {
                if ($res.Message) { "Failed ($($row.Branch)): $($res.Message)" }
                else              { "Failed ($($row.Branch))" }
            }
            default   { $row.Status }
        }
        $newStatusByLine[$row.LineNumber] = $newStatus
    }

    $repoWidth   = (@('Repo')   + ($rows | ForEach-Object { $_.Repo }))   | Measure-Object -Property Length -Maximum | Select-Object -ExpandProperty Maximum
    $branchWidth = (@('Branch') + ($rows | ForEach-Object { $_.Branch })) | Measure-Object -Property Length -Maximum | Select-Object -ExpandProperty Maximum
    $statusWidth = (@('Status') + ($rows | ForEach-Object { $newStatusByLine[$_.LineNumber] })) | Measure-Object -Property Length -Maximum | Select-Object -ExpandProperty Maximum

    $headerIndex = $null; $sepIndex = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart().StartsWith('|')) {
            if ($null -eq $headerIndex) { $headerIndex = $i; continue }
            if ($null -eq $sepIndex)    { $sepIndex    = $i; break }
        }
    }

    $newLines = @($lines)
    $newLines[$headerIndex] = "| {0} | {1} | {2} |" -f
        'Repo'.PadRight($repoWidth), 'Branch'.PadRight($branchWidth), 'Status'.PadRight($statusWidth)
    $newLines[$sepIndex] = "| {0} | {1} | {2} |" -f
        ('-' * $repoWidth), ('-' * $branchWidth), ('-' * $statusWidth)

    foreach ($row in $rows) {
        $status = $newStatusByLine[$row.LineNumber]
        $newLines[$row.LineNumber] = "| {0} | {1} | {2} |" -f
            $row.Repo.PadRight($repoWidth),
            $row.Branch.PadRight($branchWidth),
            $status.PadRight($statusWidth)
    }

    Set-Content -LiteralPath $Path -Value $newLines
}
```

Update the export:

```powershell
Export-ModuleMember -Function Parse-RepoTable, Get-StatusBranch, Resolve-Action, Sync-Repo, Write-RepoTable
```

- [ ] **Step 4: Run tests**

Run: `pwsh -Command "Invoke-Pester tests/CloneRepos.Tests.ps1 -Output Detailed"`
Expected: PASS — 16 tests passing.

- [ ] **Step 5: Commit**

```bash
git add CloneRepos.psm1 tests/CloneRepos.Tests.ps1
git commit -m "feat: add Write-RepoTable to update Status cells in place"
```

---

## Task 7: Entry-point script `clone-repos.ps1`

**Files:**
- Create: `clone-repos.ps1`
- Create: `repos.example.md`

- [ ] **Step 1: Create the example input file**

Create `repos.example.md`:

```markdown
# Repos to clone

Edit the Branch column to control which branch to clone.
Leave Status empty initially — the script fills it in.

| Repo                | Branch       | Status |
| ------------------- | ------------ | ------ |
| integrations-bundle | main         |        |
| order-service       | develop      |        |
| customer-api        | feature/auth |        |
```

- [ ] **Step 2: Create the entry-point script**

Create `clone-repos.ps1`:

```powershell
#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$File,
    [Parameter(Mandatory)][string]$Org,
    [Parameter(Mandatory)][string]$Project,
    [string]$Dest = (Get-Location).Path,
    [int]$Throttle = 5
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/CloneRepos.psm1" -Force -DisableNameChecking

if (-not (Test-Path $File)) { throw "Repo list file not found: $File" }
if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest | Out-Null }

$rows = Parse-RepoTable -Path $File
if ($rows.Count -eq 0) { Write-Host "No rows found in $File"; exit 0 }

$urlBase = "https://dev.azure.com/$Org/$Project/_git"
$destAbs = (Resolve-Path $Dest).Path
$modulePath = "$PSScriptRoot/CloneRepos.psm1"

$results = $rows | ForEach-Object -Parallel {
    Import-Module $using:modulePath -Force -DisableNameChecking
    $row = $_
    $folder = Join-Path $using:destAbs $row.Repo
    $statusBranch = Get-StatusBranch $row.Status
    $action = Resolve-Action -Branch $row.Branch -StatusBranch $statusBranch -FolderExists (Test-Path $folder)
    $url = "$using:urlBase/$($row.Repo)"
    Sync-Repo -Repo $row.Repo -Branch $row.Branch -Action $action -Url $url -Dest $using:destAbs
} -ThrottleLimit $Throttle

Write-RepoTable -Path $File -Results $results

$cloned  = @($results | Where-Object Result -eq 'Cloned').Count
$skipped = @($results | Where-Object Result -eq 'Skipped').Count
$failed  = @($results | Where-Object Result -eq 'Failed').Count

Write-Host ""
Write-Host ("Cloned: {0} . Skipped: {1} . Failed: {2} - see {3} for status." -f $cloned, $skipped, $failed, $File)

if ($failed -gt 0) {
    Write-Host ""
    foreach ($r in $results | Where-Object Result -eq 'Failed') {
        Write-Host "--- $($r.Repo) ($($r.Branch)) ---"
        Write-Host $r.Log
        Write-Host ""
    }
    exit 1
}
exit 0
```

- [ ] **Step 3: Smoke-test the help/usage**

Run: `pwsh ./clone-repos.ps1 -? `
Expected: Auto-generated parameter help showing `-File`, `-Org`, `-Project`, `-Dest`, `-Throttle`. No errors.

- [ ] **Step 4: Smoke-test on a deliberately-bad row**

Run:
```
cp repos.example.md repos.smoke.md
pwsh ./clone-repos.ps1 -File repos.smoke.md -Org bogus-org-xyz -Project bogus-proj -Dest ./_smoke_dest
```

Expected:
- Exit code `1`.
- Console summary shows `Failed: 3`.
- `repos.smoke.md` Status column now contains `Failed (<branch>): ...` for each row.
- No partial folders left behind from failed clones (git auto-cleans target on failure; verify with `ls _smoke_dest`).

Clean up: `rm -rf _smoke_dest repos.smoke.md`

- [ ] **Step 5: Commit**

```bash
git add clone-repos.ps1 repos.example.md
git commit -m "feat: add clone-repos.ps1 entry point with parallel fan-out"
```

---

## Task 8: Wire up a Pester run task & full test pass

**Files:**
- Create: `tests/run-tests.ps1` (optional convenience wrapper)

- [ ] **Step 1: Create convenience wrapper**

Create `tests/run-tests.ps1`:

```powershell
#Requires -Version 7
param([switch]$CI)
$config = New-PesterConfiguration
$config.Run.Path = "$PSScriptRoot"
$config.Output.Verbosity = if ($CI) { 'Normal' } else { 'Detailed' }
$config.Run.Exit = $CI
Invoke-Pester -Configuration $config
```

- [ ] **Step 2: Run the full suite**

Run: `pwsh ./tests/run-tests.ps1`
Expected: All 16 tests passing, no warnings about unapproved verbs (suppressed by `-DisableNameChecking`).

- [ ] **Step 3: Commit**

```bash
git add tests/run-tests.ps1
git commit -m "chore: add Pester runner wrapper"
```

---

## Task 9 (optional): Real end-to-end check

Run only if you have access to an actual Azure DevOps org/project and want to verify against the real service. Skip otherwise.

- [ ] **Step 1: Create a real `repos.md` with 1-2 real repos**
- [ ] **Step 2: Run `pwsh ./clone-repos.ps1 -File repos.md -Org <real> -Project <real>`**
- [ ] **Step 3: Verify folders exist, branches are correct (`git -C <repo> branch --show-current`), and `repos.md` Status reads `Cloned (<branch>)`**
- [ ] **Step 4: Edit the Branch column of one row to a different branch and re-run. Verify Status updates and the local checkout switched branches.**
- [ ] **Step 5: Delete the working files, do not commit** (so the real org/project name doesn't end up in the repo).
