# ConfluenceFetcherTool

Exports a Confluence Cloud page tree (a page, its descendants, and their
one-hop references) to local Markdown files with YAML frontmatter, mirroring
the Confluence hierarchy as nested folders.

## Prerequisites

- **PowerShell 7** (`pwsh`) — the entry script and module both require it (`#Requires -Version 7`).
- **pandoc** (optional but recommended) — if `pandoc` is on `PATH`, page bodies
  are converted via `pandoc -f html -t gfm-raw_html` for higher-fidelity
  Markdown. If pandoc is not found, a built-in regex-based HTML-to-Markdown
  fallback converter is used instead (see **Known limitations** below).
- A Confluence Cloud **API token** for a user with read access to the target
  space(s). Generate one at
  `https://id.atlassian.com/manage-profile/security/api-tokens`.
  - ⚠️ **Use a "classic" (non-scoped) API token.** This tool authenticates
    against the classic v1 REST API (`/wiki/rest/api`) with Basic auth.
    **Scoped** API tokens are rejected there and fail with `401`
    (see [Troubleshooting](#troubleshooting)). When creating the token, pick
    the plain "Create API token" option, **not** "Create API token with
    scopes".

## Authentication setup

The tool needs three values: `BaseUrl`, `Email`, `Token`. Provide them either
via environment variables **or** a local config file — env vars always take
precedence.

**Option A — environment variables:**

```powershell
$env:CONFLUENCE_BASE_URL  = 'https://your-site.atlassian.net/wiki'
$env:CONFLUENCE_EMAIL     = 'you@example.com'
$env:CONFLUENCE_API_TOKEN = 'your-api-token-here'
```

**Option B — config file (gitignored):**

Copy `config.example.psd1` to `config.psd1` and fill in the three values.
`config.psd1` is listed in `.gitignore` — **never commit it**.

```powershell
Copy-Item config.example.psd1 config.psd1
# then edit config.psd1 with your real BaseUrl / Email / Token
```

### Note on the auth mechanism (Constrained Language Mode)

This tool is designed to also run on servers locked to PowerShell's
**Constrained Language Mode (CLM)**. A "standard" Basic-auth implementation
would base64-encode `"email:token"` using
`[System.Text.Encoding]::UTF8.GetBytes()` and
`[System.Convert]::ToBase64String()` — but under CLM, method calls on
non-core .NET types are blocked (`"Method invocation is supported only on
core types in this language mode."`), so that approach fails outright.

Instead, `Get-AuthCredential` builds a `PSCredential` (via
`ConvertTo-SecureString` + `New-Object System.Management.Automation.PSCredential`,
both CLM-safe core-type operations), and all API calls
(`Invoke-ConfluenceApi`) authenticate with
`Invoke-RestMethod -Authentication Basic -Credential $cred` rather than a
hand-built `Authorization` header. No base64 header construction happens
anywhere in this codebase.

## Usage

```powershell
# By page URL
pwsh -NoProfile ./Export-ConfluenceDocs.ps1 -Page "https://your-site.atlassian.net/wiki/spaces/TEAM/pages/123456/Some+Page" -OutputRoot ./confluence-export

# By bare page ID
pwsh -NoProfile ./Export-ConfluenceDocs.ps1 -Page 123456 -OutputRoot ./confluence-export
```

`-OutputRoot` defaults to `./confluence-export` (relative to the current
working directory) if omitted. `-ConfigPath` defaults to `config.psd1` next
to the script, if you want to point at a different config file.

On completion the script prints a summary line, e.g.:

```
Pages fetched: 12  References: 3  Cache hits: 1  Fallback conversions: 2  Warnings: 0
```

The process exits with code `1` if any warnings were recorded (e.g.
unresolved references), otherwise `0`.

## Troubleshooting

### `Auth failed (401) ... check CONFLUENCE_EMAIL / CONFLUENCE_API_TOKEN`

The request authenticated incorrectly. Most common causes, in order:

1. **You used a scoped API token.** The classic v1 REST API this tool calls
   does **not** accept scoped tokens — it returns `401`. Generate a plain
   (non-scoped) "classic" token instead (see
   [Prerequisites](#prerequisites)).
2. **Wrong email/token pairing.** `CONFLUENCE_EMAIL` must be the Atlassian
   account email that owns the token, and the token must be current (they can
   be revoked).
3. **Wrong `BaseUrl`.** It must include the `/wiki` suffix, e.g.
   `https://your-site.atlassian.net/wiki`.

Remember env vars override `config.psd1` — if a stale `CONFLUENCE_*` env var is
set in your shell, it wins over the file. Check with
`Get-ChildItem Env:CONFLUENCE_*`.

### `API call failed (404) ... /content/=body.storage,space,ancestors,version`

Note the malformed URL — the page ID is missing and `?expand` became `=`.
This is the signature of a **known interpolation bug that is fixed in current
versions** of `ConfluenceExport.psm1`. If you see it, you are running an old
copy of the file. The fix is a one-liner in the `Get-Page` function:

```powershell
# BROKEN — PowerShell 7 parses `$PageId?` as a null-conditional variable name,
# silently dropping the id and `?expand`:
-Path "/content/$PageId?expand=body.storage,space,ancestors,version"

# FIXED — brace the variable so it terminates before the `?`:
-Path "/content/${PageId}?expand=body.storage,space,ancestors,version"
```

Apply that change (or re-copy the latest `ConfluenceExport.psm1`) and re-run.

### A genuine `404` on a real page ID

If the URL is well-formed (`/content/123456?expand=...`) and you still get
`404`, the token's account probably lacks read permission on that page/space,
or the page ID is wrong.

## Folder layout and frontmatter

Each visited page becomes a `.md` file. A page that owns children and/or
references gets its own folder (named after the page); a leaf page with no
children or references is written as a flat file next to its siblings.

Every file starts with YAML frontmatter:

```yaml
---
title: "Some Page"
pageId: "123456"
spaceKey: TEAM
sourceUrl: https://your-site.atlassian.net/wiki/spaces/TEAM/pages/123456
parentId: "123000"
lastModified: 2026-06-30T12:00:00.000Z
relationship: child
referencedFrom: null
---
```

- `relationship: child` — the page was reached by walking the Confluence
  page-tree hierarchy (parent → child).
- `relationship: reference` — the page was pulled in because a `child` page
  linked to it (a one-hop reference), and is written alongside the page that
  referenced it. `referencedFrom` holds the id of the page that linked to it.

Broken/unresolvable references are written as a stub file containing a note
explaining why resolution failed, so the export always completes rather than
aborting on a dangling link.

## Known limitations

- **v1 REST API deprecation risk.** This tool uses Confluence Cloud's classic
  `/rest/api` (v1) content endpoints. Atlassian has signaled eventual
  deprecation of v1 in favor of the v2 API; this tool may need updating if/when
  v1 is retired.
- **Text-only.** Images, attachments, and other binary content referenced in
  pages are not downloaded; only the textual/HTML body is converted to
  Markdown.
- **One-hop references only.** References found inside a `child` page's body
  are fetched and written, but references *inside those referenced pages* are
  not followed further (no recursive reference-chasing).
- **Forward-reference placement edge case.** If a page is first encountered
  as a *reference* from another page earlier in the tree walk, it gets written
  at that reference's location. If the same page is also a proper descendant
  reachable later in the walk, the cache (visited-set) causes it to be
  skipped at its "real" tree location — so it will not be duplicated, but it
  may end up placed under the referencing page's folder rather than under its
  true parent in the hierarchy.
- **Pandoc vs. fallback fidelity.** When `pandoc` is available it produces
  meaningfully higher-fidelity Markdown (better handling of tables, nested
  lists, and Confluence storage-format macros) than the built-in regex-based
  fallback converter, which only handles a common subset of HTML (headings,
  bold/italic, links, list items, paragraphs, line breaks, and fenced code
  macros). Installing pandoc is recommended for production use.
