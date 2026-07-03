# clone-repos

A PowerShell 7 tool that clones or syncs a list of Azure DevOps repositories defined in a
markdown table — in parallel — and writes per-repo status back into the same file. Re-runs are
incremental: unchanged repos are skipped, branch changes are synced, and the status column tells
you at a glance what happened.

It is built to run on locked-down servers where PowerShell is pinned to **Constrained Language
Mode** (WDAC / AppLocker), and it parallelizes there too.

## Requirements

- **PowerShell 7+** (`pwsh`) — `ForEach-Object -Parallel` is not available in Windows PowerShell 5.1.
- **git** on `PATH`.
- **Git authentication to Azure DevOps already configured** (Git Credential Manager, PAT, or SSH).
  The tool does no credential handling of its own.
- Windows (paths and the `PSModulePath` separator assume Windows).

## Usage

```powershell
.\clone-repos.ps1 -File .\repos.md -Org <azdo-org> -Project <azdo-project> [-Dest <dir>] [-Throttle <n>]
```

### Parameters

| Name | Required | Default | Description |
|---|---|---|---|
| `-File` | yes | — | Path to the markdown file containing the repo table. |
| `-Org` | yes | — | Azure DevOps organization. |
| `-Project` | yes | — | Azure DevOps project. |
| `-Dest` | no | current directory | Directory where repos are cloned (one folder per repo). Created if missing. |
| `-Throttle` | no | `5` | Max concurrent clones (1–64). |

### Example

```powershell
.\clone-repos.ps1 -File .\repos.md -Org ClasOhlson -Project COSI -Dest .\output\
```

## Input file format

A markdown table with three columns: **Repo**, **Branch**, **Status**. You maintain the `Repo`
and `Branch` columns; the script owns `Status`. Any text or blank lines outside the table
(headings, notes) are preserved in place when the file is rewritten.

```markdown
# Repos to clone

| Repo                | Branch       | Status |
| ------------------- | ------------ | ------ |
| integrations-bundle | main         |        |
| order-service       | develop      |        |
| customer-api        | feature/auth |        |
```

- Leave `Status` empty initially — the script fills it in after each run.
- The header row and the `---` separator row are skipped.
- See [`repos.example.md`](repos.example.md) for a ready-to-copy starting point.

The Azure DevOps clone URL is constructed as:

```
https://dev.azure.com/<Org>/<Project>/_git/<Repo>
```

## Behavior

For each row the script picks an action from the requested **Branch**, the branch parsed from the
`Status` cell's parenthetical, and whether `<Dest>/<Repo>` exists on disk:

| Branch | Status `(branch)` | Folder on disk | Action |
|---|---|---|---|
| `X` | empty / `Failed (*)` | — | **Clone** |
| `X` | `(X)` | exists | **Skip** |
| `X` | `(X)` | missing | **Clone** |
| `X` | `(Y)`, `Y ≠ X` | exists | **Switch** (`fetch` + `checkout X` + `pull --ff-only`) |
| `X` | `(Y)`, `Y ≠ X` | missing | **Clone** |

- **Clone** wipes the destination folder first if it already exists, then `git clone --branch X`.
  This means a re-run never fails with *"destination path already exists"* — but note it
  **deletes** any local changes or untracked files in that folder.
- **Switch** moves an existing checkout to a different branch without re-downloading.
- **Skip** does nothing when the folder is already on the requested branch.

### Status values written by the script

- `Cloned (X)` — success (fresh clone or branch switch).
- `Failed (X): <reason>` — failure; the reason is the last line of the captured git output.
- Empty — never written by the script; only a user-authored initial state.

One failure never stops the rest: every row is processed, the file is rewritten so successful
rows reflect their new status, and failures are listed afterward.

## Output

A colorized one-line summary (green/cyan/red), followed by the captured log for each failure:

```
Cloned: 2 . Skipped: 1 . Failed: 1 - see repos.md for status.

--- customer-api (feature/auth) ---
fatal: Remote branch feature/auth not found in upstream origin
```

Color is automatically dropped when output is redirected to a file or pipe.

### Exit code

- `0` — no failures.
- `1` — at least one row resulted in `Failed`.

## Constrained Language Mode (locked-down servers)

On servers pinned to Constrained Language Mode, two things would normally break and are handled:

- The module avoids constructs CLM forbids (`New-Object` for non-core types, `[pscustomobject]`
  casts) — it uses plain hashtables and arrays.
- `ForEach-Object -Parallel` runspaces cannot `Import-Module` a path passed via `$using:`
  (marshaled values are treated as untrusted). Instead, the script stages the module into a
  name-importable folder on `PSModulePath` at startup and imports it **by name**, which is
  allowed. Parallel execution therefore works in every language mode.

## Project layout

| File | Purpose |
|---|---|
| `clone-repos.ps1` | Entry point: argument parsing, module staging, parallel fan-out, file rewrite, summary, exit code. |
| `CloneRepos.psm1` | Module: `Parse-RepoTable`, `Get-StatusBranch`, `Resolve-Action`, `Sync-Repo`, `Write-RepoTable`. |
| `repos.example.md` | Example input file. |
| `tests/CloneRepos.Tests.ps1` | Pester 5 unit tests for all five functions. |
| `tests/clm-smoke.ps1` | Constrained Language Mode regression guard (forces CLM, exercises every path incl. parallel import). |
| `tests/run-tests.ps1` | Convenience Pester runner. |
| `docs/superpowers/specs/` | Design documents. |

## Testing

Requires Pester 5 (`Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser`).

```powershell
# Unit tests
pwsh .\tests\run-tests.ps1            # add -CI for a non-zero exit on failure

# Constrained Language Mode smoke test
pwsh -File .\tests\clm-smoke.ps1
```

## Out of scope

- Authentication setup (PAT / SSH configuration).
- Cloning from hosts other than Azure DevOps.
- Submodule handling.
- Preserving uncommitted local changes — `Switch` lets `git checkout` refuse conflicting changes
  (surfaced as `Failed`), and `Clone` deliberately wipes the destination folder.
- Removing folders for repos that have been deleted from the table.
