# tools-for-bundle-test-creation

A collection of PowerShell 7 tools that gather the raw material — source code and
documentation — needed to build and test integration bundles. Both tools are built
to run on locked-down servers pinned to PowerShell's **Constrained Language Mode**
(WDAC / AppLocker), and each has its own detailed README.

## Tools

| Tool | What it does |
|---|---|
| [**RepoClonerTool**](RepoClonerTool/README.md) | Clones or syncs a list of Azure DevOps repositories — defined in a markdown table — in parallel, and writes per-repo status back into the same file. Re-runs are incremental. |
| [**ConfluenceFetcherTool**](ConfluenceFetcherTool/README.md) | Exports a Confluence Cloud page tree (a page, its descendants, and their one-hop references) to local Markdown files with YAML frontmatter, mirroring the Confluence hierarchy as nested folders. |

## RepoClonerTool

Clones/syncs Azure DevOps repos listed in a markdown table, choosing per-row between
**Clone**, **Switch**, and **Skip** based on the requested branch, the last recorded
status, and what's on disk. Failures never stop the rest of the run; each row's outcome
is written back to the `Status` column.

```powershell
.\clone-repos.ps1 -File .\repos.md -Org <azdo-org> -Project <azdo-project> [-Dest <dir>] [-Throttle <n>]
```

- **Requires:** PowerShell 7+, `git` on `PATH`, and Git auth to Azure DevOps already
  configured (Credential Manager / PAT / SSH). Windows.
- **Input:** a markdown table with `Repo`, `Branch`, `Status` columns (you own the first
  two; the script owns `Status`).
- **Parallel:** `ForEach-Object -Parallel`, throttled (default 5), CLM-safe.

See [RepoClonerTool/README.md](RepoClonerTool/README.md) for the action matrix, status
values, and CLM details.

## ConfluenceFetcherTool

Walks a Confluence Cloud page hierarchy and exports each page to a `.md` file with YAML
frontmatter, preserving the parent/child folder structure and pulling in one-hop
references. Uses `pandoc` for high-fidelity HTML→Markdown when available, with a built-in
regex fallback otherwise.

```powershell
pwsh -NoProfile ./Export-ConfluenceDocs.ps1 -Page <url-or-pageId> -OutputRoot ./confluence-export
```

- **Requires:** PowerShell 7. `pandoc` is optional but recommended.
- **Auth:** a **classic (non-scoped)** Confluence Cloud API token, supplied via
  `CONFLUENCE_BASE_URL` / `CONFLUENCE_EMAIL` / `CONFLUENCE_API_TOKEN` env vars or a
  gitignored `config.psd1`. Env vars take precedence.
- **Output:** nested Markdown mirroring the page tree; frontmatter records `pageId`,
  `spaceKey`, `sourceUrl`, `relationship` (child vs. reference), and more.

See [ConfluenceFetcherTool/README.md](ConfluenceFetcherTool/README.md) for auth setup,
troubleshooting (notably scoped-token 401s), and known limitations.

## Common notes

- **PowerShell 7 (`pwsh`) is required** for both tools — Windows PowerShell 5.1 lacks
  features they depend on.
- **Constrained Language Mode:** both tools deliberately avoid CLM-forbidden constructs
  and are exercised by CLM smoke tests under each tool's `tests/` folder.
- **Testing:** each tool ships Pester 5 tests plus a CLM regression guard; run via
  `pwsh .\tests\run-tests.ps1` in the respective directory.
</content>
</invoke>
