# Confluence Docs Export — Design

**Date:** 2026-07-01
**Status:** Approved (pending spec review)
**Author:** Mojtaba Rezaei

## Purpose

A standalone PowerShell tool that exports Confluence Cloud documentation to the
local PC as Markdown, so an AI agent can work with it offline. Given a single
starting page, it recursively downloads the page and all of its descendants into
a folder hierarchy that mirrors the Confluence page tree, and additionally pulls
in one-hop referenced pages linked from any downloaded page.

## Requirements

- **Access:** Standalone script using the Confluence Cloud REST API with the
  user's own API token (email + token, Basic auth). Not dependent on any chat
  session or connector.
- **Entry point:** A single Confluence page — accepted as a full page URL or a
  bare page ID.
- **Descendants:** Download the start page and every page beneath it, stored in a
  folder hierarchy mirroring the Confluence tree.
- **References:** For any Confluence page linked from a downloaded page that is
  **not** part of the descendant subtree, fetch that linked page **once, one hop
  only** (no recursion into its children or its own outbound links). Store it as
  a direct sibling file alongside the calling page's content.
- **Caching:** Fetch each referenced page from the API at most once. Maintain a
  cache keyed by page ID; on any re-mention, copy the already-downloaded local
  file to the new location instead of calling the API again. The cache also acts
  as the visited-set that prevents infinite loops.
- **Format:** Text-only Markdown (with YAML frontmatter). No images or file
  attachments are downloaded.
- **Conversion:** HTML/XHTML storage format → Markdown via pandoc when available,
  with a built-in fallback converter otherwise.
- **Runtime constraint:** Must run under PowerShell **Constrained Language Mode
  (CLM)** — the same lockdown as the COSI server — as well as full language mode.

## Confluence target

- **Confluence Cloud** (`*.atlassian.net`).
- API base: `<baseUrl>/wiki/rest/api` (e.g. `https://<site>.atlassian.net/wiki`).
- Page body retrieved in `storage` format (XHTML with Confluence `ac:`/`ri:`
  macro tags).
- **API version — known risk:** this design uses the Confluence Cloud **v1** REST
  API (`/wiki/rest/api`). Atlassian is deprecating v1 in favour of v2
  (`/wiki/api/v2`). v1 is accepted here because (a) it is still served on the
  COSI-reachable instance and (b) this is a short-lived internal export tool. The
  fragile v1 dependency — title-based content lookup — is minimized by resolving
  references from embedded page IDs first (see Reference extractor/resolver) so the
  title endpoint is hit rarely. If v1 is withdrawn, only the API client's base path
  and the resolver need to move to v2. First implementation step should confirm the
  v1 endpoints still respond on the target instance.

## CLM compliance rules

The COSI server runs PowerShell under CLM (WDAC/AppLocker). See the project's
`clm-constraint` memory. This tool follows the same rules:

- **No DOM/XML parsing** of page bodies. Reference extraction is **regex-based**
  (`[regex]::Match` is confirmed CLM-allowed) against the storage-format XHTML.
- **Collections:** visited/cache store is a plain `@{}` hashtable (its
  `.ContainsKey()` and indexing are core-type operations, allowed); page lists
  use `@()` + `+=`. No `[pscustomobject]`, no
  `System.Collections.Generic.List`.
- **Paths:** `Join-Path` / `Split-Path` cmdlets only — no `[System.IO.Path]`
  methods.
- **URL-encoding:** performed by `Invoke-RestMethod -Body @{title=…; spaceKey=…}`
  on a GET, so the cmdlet builds the encoded query string — avoids the banned
  `[uri]::EscapeDataString`.
- **Data objects:** plain hashtables `@{}` (members accessed as `$x.Prop`).
- **Execution is sequential**, not `ForEach-Object -Parallel`. The recursion
  shares one mutable cache dictionary; parallel runspaces would race on it and
  reintroduce module-marshaling issues. Throughput is not a concern for an
  occasional docs export.

### Auth header — verify-first item

Cloud Basic auth requires base64-encoding `email:token`. The usual path is
`[System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(...))`,
but those method calls may be banned under CLM just as `[System.IO.Path]` is.

**This is the first thing to verify at implementation time**, using the local
CLM test harness (`$ExecutionContext.SessionState.LanguageMode =
'ConstrainedLanguage'`):

1. Test whether the `[System.Convert]` / `[System.Text.Encoding]` base64 path
   works under CLM.
2. If it does not, fall back to `Invoke-RestMethod -Authentication Basic
   -Credential …`, resolving how to build the `PSCredential` in a CLM-safe way.

The auth approach is locked down and verified before any crawling logic is
built.

## Architecture

A single script, `Export-ConfluenceDocs.ps1`, organized into focused functions:

- **Config/auth** — reads `CONFLUENCE_BASE_URL`, `CONFLUENCE_EMAIL`,
  `CONFLUENCE_API_TOKEN` from environment variables or a gitignored config file;
  builds the auth header (per the verified approach above). Credentials are never
  hardcoded.
- **API client** — `Invoke-ConfluenceApi` wrapper: handles paging and retry with
  backoff on 429/5xx; surfaces 401/403 as an early fatal error.
- **Fetcher** — `Get-Page` (body in `storage` format, plus `title`, `space`,
  `ancestors`, `version`), `Get-ChildPages` (paged).
- **Reference extractor** — `Get-PageReferences`: regex over storage XHTML for
  the reference link forms. **ID-bearing forms are preferred** because they need
  no lookup: `<ri:page ri:content-id="{id}" …/>` and
  `<a href="…/pages/{id}/…">`. The **title-only** form
  (`<ac:link><ri:page ri:content-title="…" ri:space-key="…"/></ac:link>`, no
  `ri:content-id`) is the only case that must fall through to the resolver.
- **Reference resolver** — used **only when a reference carries no page ID**.
  Resolves a `(title, spaceKey)` reference to a page ID via
  `GET content?title=…&spaceKey=…` (encoding via `-Body` hashtable).
  **Ambiguity rule:** if the lookup returns multiple pages, prefer the match in
  the same `spaceKey`; if still more than one, pick the highest `version.number`
  and log a warning naming the caller page and the chosen ID. Zero matches → treat
  as a broken reference (404 stub path, below).
- **Converter** — `Convert-ToMarkdown`: pandoc if present
  (`pandoc -f html -t gfm-raw_html`), else the built-in regex fallback.
- **Writer** — filename/path sanitizing (Windows-safe), folder-tree layout, YAML
  frontmatter emission.
- **Orchestrator** — recursive descendant walk + reference handling + the
  visited/cache hashtable + run summary.

## Data flow

1. Resolve the start page ID (from URL or bare ID).
2. Recursively walk descendants depth-first:
   - Fetch page (storage body + metadata).
   - Convert body to Markdown, prepend frontmatter, write to disk.
   - Record page ID in the cache/visited hashtable.
   - Extract references; for each reference outside the descendant subtree,
     handle it via the reference path (below).
   - Fetch child pages and recurse.
3. Reference path for a non-descendant linked page:
   - Determine the page ID: use the embedded ID if the link carried one; otherwise
     resolve it via the title lookup + ambiguity rule (Reference resolver).
   - If page ID already in cache → `Copy-Item` the cached local file into the
     calling page's folder.
   - Else fetch once (one hop), convert, write alongside the calling page, record
     in cache.
4. Emit run summary.

## Folder layout

The descendant tree mirrors the Confluence hierarchy. A page becomes a **folder**
if it has children **or** outbound references; its own content lives in
`<PageName>.md` inside that folder. A leaf page with no references is a plain
`.md` file. Referenced pages are written as **direct sibling files** in the
calling page's folder.

```
<output-root>/
  Integrations/
    Integrations.md
    INT0001 - xxxx/
      INT0001 - xxxx.md
      INT0001.i001 - xxxxx/
        INT0001.i001 - xxxxx.md      ← the page's own content
        ModelForX.md                 ← referenced page, alongside the caller
```

- Filenames sanitized for Windows: strip `\ / : * ? " < > |`, collapse
  whitespace, trim length. Title collisions get the page ID appended:
  `Title-123456.md`.
- If a referenced page's sanitized name would collide with a real child's, the
  page ID is appended to disambiguate.

## Frontmatter

Each `.md` file begins with YAML frontmatter:

```yaml
---
title: INT0001.i001 - xxxxx
pageId: "123456"
spaceKey: INT
sourceUrl: https://<site>.atlassian.net/wiki/spaces/INT/pages/123456/...
parentId: "123400"
lastModified: 2026-06-15T09:30:00Z
relationship: child        # child | reference
referencedFrom: null       # pageId of the caller, when relationship = reference
---
```

`relationship` and `referencedFrom` let both the user and an AI agent distinguish
genuine child pages from pulled-in referenced pages, which otherwise look
identical on disk (both plain `.md` siblings).

## Conversion

- `Get-Command pandoc` decides the path.
- **pandoc present:** pipe storage HTML through `pandoc -f html -t gfm-raw_html`.
- **pandoc absent:** built-in regex fallback converts headings, bold/italic,
  links, lists, tables, and `<ac:structured-macro ac:name="code">` blocks to
  fenced code. Good enough for AI consumption; logs which pages used the
  fallback.

## Error handling

- API wrapper retries on 429/5xx with backoff; logs via `$_.Exception.Message`
  (CLM-safe).
- 401/403 → stop early with a clear message rather than failing on every page.
- 404 on a referenced page (deleted/missing) → log a warning, write a small stub
  `.md` noting the broken reference, continue.
- End-of-run summary: pages fetched, references pulled, cache hits, fallback
  conversions, warnings.

## Out of scope (YAGNI)

- Images and file attachments (text-only export).
- Recursing beyond one hop for referenced pages.
- Parallel execution.
- Confluence Server / Data Center support (Cloud only).
- Incremental / delta sync (full export each run).

## Verification plan

- CLM smoke test analogous to clone-repos' `tests/clm-smoke.ps1`: run the script's
  core paths with `$ExecutionContext.SessionState.LanguageMode =
  'ConstrainedLanguage'` to guarantee no banned constructs.
- The auth-header verification (above) is the first implementation step and gates
  everything else.
