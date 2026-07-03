#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$File,
    [Parameter(Mandatory)][string]$Org,
    [Parameter(Mandatory)][string]$Project,
    [string]$Dest = (Get-Location).Path,
    [ValidateRange(1, 64)][int]$Throttle = 5
)

$ErrorActionPreference = 'Stop'

# The module lives at the repo root (CloneRepos.psm1). To make it importable by
# NAME — required inside ForEach-Object -Parallel runspaces, which can't
# Import-Module a $using:/pipeline path under Constrained Language Mode because
# marshaled values are "untrusted" — stage a copy into a name-importable folder
# (<dir>/CloneRepos/CloneRepos.psm1) and put that dir on PSModulePath. Runspaces
# inherit process env vars, so they can then Import-Module CloneRepos by name.
$moduleStage = Join-Path $env:TEMP 'clone-repos-module'
$null = New-Item -ItemType Directory -Path (Join-Path $moduleStage 'CloneRepos') -Force
Copy-Item "$PSScriptRoot/CloneRepos.psm1" (Join-Path $moduleStage 'CloneRepos/CloneRepos.psm1') -Force
$env:PSModulePath = "$moduleStage;$env:PSModulePath"
Import-Module CloneRepos -Force -DisableNameChecking

if (-not (Test-Path $File)) { throw "Repo list file not found: $File" }
if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest | Out-Null }

$rows = Parse-RepoTable -Path $File
if ($rows.Count -eq 0) {
    # Verifies the file actually contains a table; throws "No markdown table found" otherwise.
    Write-RepoTable -Path $File -Results @()
    Write-Host "No rows found in $File"
    exit 0
}

$urlBase = "https://dev.azure.com/$Org/$Project/_git"
$destAbs = (Resolve-Path $Dest).Path

$results = $rows | ForEach-Object -Parallel {
    Import-Module CloneRepos -Force -DisableNameChecking
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
Write-Host "Cloned: $cloned"   -ForegroundColor Green -NoNewline
Write-Host " . "                                      -NoNewline
Write-Host "Skipped: $skipped" -ForegroundColor Cyan  -NoNewline
Write-Host " . "                                      -NoNewline
$failedColor = if ($failed -gt 0) { 'Red' } else { 'DarkGray' }
Write-Host "Failed: $failed"   -ForegroundColor $failedColor -NoNewline
Write-Host " - see $File for status."

if ($failed -gt 0) {
    Write-Host ""
    foreach ($r in $results | Where-Object Result -eq 'Failed') {
        Write-Host "--- $($r.Repo) ($($r.Branch)) ---" -ForegroundColor Red
        Write-Host $r.Log
        Write-Host ""
    }
    exit 1
}
exit 0
