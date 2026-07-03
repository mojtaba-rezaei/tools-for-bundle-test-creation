# Clone Repos Script — Design

**Date:** 2026-06-26
**Status:** Approved
**Owner:** mojtaba.rezaei@contica.se

## Goal

A PowerShell script that reads a markdown table listing Azure DevOps repos and target branches, clones or syncs each one in parallel, and uses the same file to track per-repo status across runs.

## Usage

```powershell
pwsh ./clone-repos.ps1 -File repos.md -Org <azdo-org> -Project <azdo-project> [-Dest <dir>] [-Throttle <n>]
```

### Parameters

| Name | Required | Default | Description |
|---|---|---|---|
| `-File` | yes | — | Path to the markdown file containing the repo table. |
| `-Org` | yes | — | Azure DevOps organization. |
| `-Project` | yes | — | Azure DevOps project. |
| `-Dest` | no | current working directory | Directory where repos are cloned (one folder per repo). |
| `-Throttle` | no | `5` | Max concurrent clones (`ForEach-Object -Parallel` throttle). |

## Input File Format

A markdown table with three columns: `Repo`, `Branch`, `Status`. Free text and blank lines outside the table are preserved on rewrite.

```markdown
| Repo                | Branch       | Status         |
| ------------------- | ------------ | -------------- |
| integrations-bundle | main         |                |
| order-service       | develop      | Cloned (main)  |
| customer-api        | feature/auth | Cloned (main)  |
```

- The user maintains the `Repo` and `Branch` columns.
- The `Status` column is owned by the script — initial values are empty; the script writes back after each run.
- Header row and `---` separator row are skipped.
- Any line that does not start with `|` is preserved as-is in its original position.

## Behavior

### Decision Matrix

For each row, the script picks an action based on the requested `Branch`, the parenthetical branch parsed from the `Status` cell, and whether `<Dest>/<Repo>` exists on disk.

| Branch | Status parens | Folder on disk | Action |
|---|---|---|---|
| `X` | empty / `Failed (*)` | — | `git clone --branch X` |
| `X` | `(X)` | exists | skip |
| `X` | `(X)` | missing | `git clone --branch X` |
| `X` | `(Y)` where `Y ≠ X` | exists | `git fetch` + `git checkout X` + `git pull --ff-only` |
| `X` | `(Y)` where `Y ≠ X` | missing | `git clone --branch X` |

### Status Values Written by the Script

- `Cloned (X)` — success (fresh clone or branch switch).
- `Failed (X): <short reason>` — failure. The reason is the last line of the captured git error, truncated to fit on one cell line.
- Empty — never written by the script; only ever a user-authored initial state.

### Authentication

The script assumes git authentication to Azure DevOps is already configured (Git Credential Manager, PAT, or SSH). No credential handling is built in.

## Components

| Function | Responsibility |
|---|---|
| `Parse-RepoTable` | Reads the file. Returns a structured list of rows `[{Repo, Branch, Status, LineNumber}]` plus the original line array. Skips header and separator rows; preserves non-table lines. |
| `Get-StatusBranch` | Extracts the `(<branch>)` parenthetical from a Status cell, or `$null` if absent. |
| `Resolve-Action` | Given `Branch`, parsed Status branch, and folder existence, returns one of `Skip`, `Clone`, `Switch`. |
| `Sync-Repo` | Runs the resolved action. Returns `@{ Repo; Branch; Result; Message; Log }` where `Result ∈ { Cloned, Skipped, Failed }`. All git output is captured into `Log`, not streamed. |
| `Write-RepoTable` | Rewrites the file in place. Updates only the `Status` cells based on results. Preserves non-table lines and row order. Recomputes column widths so the rewritten table stays aligned. |
| `main` block | Parses args, parses table, fans out via `ForEach-Object -Parallel -ThrottleLimit $Throttle`, merges results by `Repo`, rewrites the file, prints console summary, sets exit code. |

## URL Construction

```
https://dev.azure.com/<Org>/<Project>/_git/<Repo>
```

## Parallel Execution

- `ForEach-Object -Parallel` with `-ThrottleLimit $Throttle` (default 5).
- Each runspace captures its own git stdout/stderr into a `Log` string and never writes directly to the console — this prevents interleaving.
- After all runspaces complete, results are merged back into the parsed table by `Repo` name and the file is rewritten in a single pass.

## Error Handling

- Any thrown exception or non-zero git exit code inside a runspace is caught; that row's `Result` becomes `Failed` and the captured log goes into `Message`.
- One failure never stops the rest — the script always processes every row.
- After all runspaces finish, the file is rewritten so successful rows reflect their new status even if others failed.

## Console Output

A single summary line, followed by the captured log for each failure:

```
Cloned: 2 · Skipped: 1 · Failed: 1 — see repos.md for status, details below.

--- customer-api (feature/auth) ---
fatal: Remote branch feature/auth not found in upstream origin
```

## Exit Code

- `0` — no failures.
- `1` — at least one row resulted in `Failed`.

## Requirements

- PowerShell 7+ (`pwsh`) — `ForEach-Object -Parallel` is not in Windows PowerShell 5.1.
- `git` on `PATH`.
- Git authentication to Azure DevOps already configured.

## Out of Scope

- Authentication setup (PAT / SSH key configuration).
- Cloning from hosts other than Azure DevOps.
- Submodule handling.
- Preserving uncommitted local changes when switching branches — `git checkout` will refuse if there are conflicting changes; that surfaces as a `Failed` row.
- Removing folders for repos that have been deleted from the table.
