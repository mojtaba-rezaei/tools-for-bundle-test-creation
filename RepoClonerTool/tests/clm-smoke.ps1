#Requires -Version 7
# Constrained Language Mode smoke test.
#
# Locked-down servers (WDAC / AppLocker / Device Guard) pin PowerShell to
# ConstrainedLanguage, which forbids `New-Object` for non-core types and
# `[pscustomobject]` casts. This script forces that mode and exercises every
# object-creating code path so the tool is verified to run on such servers.
#
# Exit 0 = all paths work under CLM. Exit 1 = a construct was blocked.

$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/../CloneRepos.psm1" -Force -DisableNameChecking

$failures = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { Write-Host "OK    : $name" }
    else     { Write-Host "FAIL  : $name -> $detail"; $script:failures++ }
}

try {
    $tmp = New-TemporaryFile
    @'
# Repos

| Repo  | Branch | Status |
| ----- | ------ | ------ |
| alpha | main   | Cloned (main) |
| beta  | dev    |        |
'@ | Set-Content $tmp

    # Parse-RepoTable (List + pscustomobject)
    $rows = Parse-RepoTable -Path $tmp
    Check 'Parse-RepoTable returns 2 rows' ($rows.Count -eq 2) "got $($rows.Count)"
    Check 'row property access works' ($rows[0].Repo -eq 'alpha') "got '$($rows[0].Repo)'"

    # Get-StatusBranch ([regex])
    Check 'Get-StatusBranch parses parenthetical' ((Get-StatusBranch 'Cloned (main)') -eq 'main') 'parse failed'

    # Resolve-Action
    Check 'Resolve-Action -> Skip' ((Resolve-Action -Branch 'main' -StatusBranch 'main' -FolderExists $true) -eq 'Skip') 'wrong action'

    # Sync-Repo Skip path (returns a hashtable, no git needed)
    $r = Sync-Repo -Repo 'alpha' -Branch 'main' -Action 'Skip' -Url 'x' -Dest 'x'
    Check 'Sync-Repo Skip returns Skipped' ($r.Result -eq 'Skipped') "got '$($r.Result)'"

    # Write-RepoTable end-to-end
    $results = @(
        @{ Repo = 'alpha'; Branch = 'main'; Result = 'Cloned'; Message = '' }
        @{ Repo = 'beta';  Branch = 'dev';  Result = 'Failed'; Message = 'boom' }
    )
    Write-RepoTable -Path $tmp -Results $results
    $content = Get-Content $tmp -Raw
    Check 'Write-RepoTable wrote Cloned status' ($content -match 'Cloned \(main\)') 'status missing'
    Check 'Write-RepoTable wrote Failed status' ($content -match 'Failed \(dev\): boom') 'status missing'

    Remove-Item $tmp -ErrorAction SilentlyContinue

    # Parallel fan-out via import-by-name — the exact path clone-repos.ps1 takes.
    # Under CLM, runspaces can only Import-Module a literal NAME discovered on
    # PSModulePath (a $using:/pipeline path would be rejected as untrusted). The
    # root module is staged into a name-importable folder, mirroring the script.
    $toolDir = Split-Path $PSScriptRoot -Parent
    $stage = Join-Path $env:TEMP 'clm-smoke-module'
    $null = New-Item -ItemType Directory -Path (Join-Path $stage 'CloneRepos') -Force
    Copy-Item "$toolDir/CloneRepos.psm1" (Join-Path $stage 'CloneRepos/CloneRepos.psm1') -Force
    $env:PSModulePath = "$stage;$env:PSModulePath"
    $par = @('one', 'two') | ForEach-Object -Parallel {
        Import-Module CloneRepos -Force -DisableNameChecking
        Sync-Repo -Repo $_ -Branch 'main' -Action 'Skip' -Url 'x' -Dest 'x'
    } -ThrottleLimit 2
    $parSkipped = @($par | Where-Object Result -eq 'Skipped').Count
    Check 'parallel import-by-name fan-out works under CLM' ($parSkipped -eq 2) "got $parSkipped skipped"
}
catch {
    Write-Host "FAIL  : unhandled exception -> $($_.Exception.Message)"
    $failures++
}

Write-Host ""
if ($failures -eq 0) { Write-Host "CLM smoke test PASSED"; exit 0 }
else { Write-Host "CLM smoke test FAILED ($failures)"; exit 1 }
