# Clone Repos Improvements — Design

**Date:** 2026-06-29
**Status:** Approved
**Owner:** mojtaba.rezaei@contica.se
**Builds on:** `2026-06-26-clone-repos-design.md`

## Goal

Three improvements to the existing `clone-repos` tool, driven by real use on the locked-down ClasOhlson COSI server (PowerShell Constrained Language Mode):

1. Stop failing when the destination folder already exists.
2. Colorize the console summary so cloned / skipped / failed are easy to scan.
3. Restore parallel execution in all environments, including Constrained Language Mode (CLM).

## Background

The COSI server pins PowerShell to **Constrained Language Mode**. A prior fix made the
module CLM-safe (arrays + hashtables instead of `New-Object` / `[pscustomobject]`) and fell
back to **sequential** execution under CLM, because `ForEach-Object -Parallel` could not
`Import-Module` a `$using:`/pipeline path (CLM marks marshaled values "untrusted"). On the
server, the user then hit two more issues: a `Clone` against an existing folder fails, and
the sequential fallback is slow.

Research findings (verified by forcing CLM in a child `pwsh`):

- `Import-Module <LiteralName>` works inside a parallel runspace under CLM **when the module
  is discoverable on `$env:PSModulePath`** (environment variables are inherited by runspaces).
- Dot-sourcing a `$using:` path inside `-Parallel` does **not** make the functions available.
- The same import-by-name approach works in FullLanguage too — so a single parallel path
  serves both modes and the sequential fallback can be removed.

## Feature 1: Wipe-before-clone

The incremental decision matrix (Skip / Switch / Clone) from the base design is unchanged.
The only change is inside the **Clone** action of `Sync-Repo`:

```
If the target folder exists, Remove-Item -Recurse -Force it, then git clone.
```

- Fixes `fatal: destination path '<dir>' already exists and is not an empty directory.`
- A log line ("Removed existing folder before clone: <target>") is appended to the captured
  `Log` so the action is visible.
- Skip and Switch are untouched, so unchanged repos are not re-downloaded on re-runs.

### Decision matrix (unchanged from base design)

| Branch | Status parens | Folder on disk | Action |
|---|---|---|---|
| `X` | empty / `Failed (*)` | — | `Clone` (wipes folder first if present) |
| `X` | `(X)` | exists | `Skip` |
| `X` | `(X)` | missing | `Clone` |
| `X` | `(Y)` where `Y ≠ X` | exists | `Switch` |
| `X` | `(Y)` where `Y ≠ X` | missing | `Clone` |

Consequence (accepted): empty status + existing folder resolves to `Clone`, which now wipes
and re-clones. This matches the chosen rule "wipe only when a clone is needed."

## Feature 2: Colorized console output

In `clone-repos.ps1`, the summary line is rendered with colored counts using
`Write-Host -NoNewline -ForegroundColor`:

- **Cloned** → Green
- **Skipped** → Cyan
- **Failed** → Red when `> 0`, default/gray when `0`

Each failure block header `--- <repo> (<branch>) ---` is printed in Red; the captured log
follows in default color.

`Write-Host -ForegroundColor` is CLM-safe and color is automatically dropped when output is
redirected to a file or pipe, so logs stay clean.

## Feature 3: Parallel in all environments (including CLM)

### Module layout

The module file stays at the repo root (`CloneRepos.psm1`). PowerShell only discovers modules
by *name* via the `<dir>/<Name>/<Name>.psm1` folder layout, so to import by name (required in
parallel runspaces under CLM) the script stages a copy at runtime into a name-importable folder
on `PSModulePath`. The module name stays `CloneRepos`, so `Mock -ModuleName CloneRepos` in tests
is unaffected.

### Entry point changes (`clone-repos.ps1`)

1. Stage the root module into a per-run, name-importable folder and put it on the module search
   path so `CloneRepos` is discoverable by name in this process and in child runspaces:
   ```powershell
   $moduleStage = Join-Path $env:TEMP 'clone-repos-module'
   $null = New-Item -ItemType Directory -Path (Join-Path $moduleStage 'CloneRepos') -Force
   Copy-Item "$PSScriptRoot/CloneRepos.psm1" (Join-Path $moduleStage 'CloneRepos/CloneRepos.psm1') -Force
   $env:PSModulePath = "$moduleStage;$env:PSModulePath"
   ```
   (Windows-only tool; `;` is the correct separator. `$env:TEMP` is used rather than
   `[System.IO.Path]::GetTempPath()`, which is a blocked method call under CLM.)
2. Import for the parent scope by name: `Import-Module CloneRepos -Force -DisableNameChecking`.
3. Replace the language-mode branch with a single parallel fan-out for **all** environments:
   ```powershell
   $results = $rows | ForEach-Object -Parallel {
       Import-Module CloneRepos -Force -DisableNameChecking
       ...
       Sync-Repo -Repo $row.Repo -Branch $row.Branch -Action $action -Url $url -Dest $using:destAbs
   } -ThrottleLimit $Throttle
   ```
4. Remove the `if ($ExecutionContext.SessionState.LanguageMode -eq 'ConstrainedLanguage')`
   sequential branch and its "running sequentially" message.

Note: `$using:` string values (`$using:destAbs`, `$using:urlBase`) remain fine under CLM —
the untrusted-value restriction only applies to sensitive parameters like `Import-Module -Name`,
not to ordinary string arguments. Import is now by literal name, so it is trusted.

## Files Touched

| File | Change |
|---|---|
| `CloneRepos.psm1` | Stays at repo root; add wipe-before-clone to the Clone action. |
| `clone-repos.ps1` | Runtime module staging + import-by-name, drop CLM branch, colorized output. |
| `tests/CloneRepos.Tests.ps1` | Add a wipe-before-clone test (imports the module by path). |
| `tests/clm-smoke.ps1` | Update import path; retain as a CLM regression guard. |

## Testing

- **New unit test** (`Sync-Repo - Clone over existing folder`): pre-create the target folder
  with a sentinel file, mock `git`, run the Clone action, and assert the sentinel is gone
  (folder was wiped) and `git clone` was invoked with the right URL/branch.
- **Existing 18 Pester tests** continue to pass after the import-path update.
- **CLM smoke test** continues to pass and is extended to exercise the import-by-name parallel
  path (forces CLM, stages module on `PSModulePath`, runs a small `-Parallel` fan-out).

## Out of Scope

- Smarter handling of empty-status + existing git repo (e.g. syncing instead of re-cloning) —
  explicitly deferred per the "wipe only when cloning is needed" decision.
- Preserving uncommitted local changes when a folder is wiped before clone — wiping is
  intentional and destroys the folder contents.
- Cross-platform path-separator handling for `PSModulePath` (tool is Windows/Azure DevOps only).
