# Confluence Docs Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Export-ConfluenceDocs.ps1`, a standalone PowerShell 7 tool that exports a Confluence Cloud page and its descendants (plus one-hop referenced pages) to local Markdown for an AI agent to consume.

**Architecture:** All logic lives in a root module `ConfluenceExport.psm1` as small, single-responsibility functions; a thin entry script `Export-ConfluenceDocs.ps1` loads config, imports the module, and runs the recursive orchestrator. Pure functions (parsing, sanitizing, reference extraction, conversion, frontmatter, path layout, retry decisions) are unit-tested with Pester; the networked functions are thin wrappers validated by a CLM smoke test and a manual run against a real instance.

**Tech Stack:** PowerShell 7, Pester 5, Confluence Cloud REST API v1 (`/wiki/rest/api`), optional `pandoc` (with a built-in regex fallback converter — pandoc is NOT installed on the dev machine, so the fallback is the primary tested path).

## Global Constraints

Copied verbatim from `docs/superpowers/specs/2026-07-01-confluence-docs-export-design.md`. Every task's requirements implicitly include this section.

- **Must run under PowerShell Constrained Language Mode (CLM)** as well as full language mode. CLM rules:
  - No DOM/XML parsing — reference extraction is **regex-based** (`[regex]::Match`/`[regex]::Matches` and `[regex]::Replace` are CLM-allowed).
  - Collections: cache/visited store is a plain `@{}` hashtable; lists use `@()` + `+=`. **No** `[pscustomobject]` casts, **no** `System.Collections.Generic.List`, **no** `New-Object` of non-core types.
  - Paths: `Join-Path` / `Split-Path` cmdlets only — **no** `[System.IO.Path]` methods.
  - URL-encoding: done by `Invoke-RestMethod -Body @{...}` on a GET — **no** `[uri]::EscapeDataString`.
  - Data objects: plain hashtables `@{}` (members accessed as `$x.Prop`).
  - Execution is **sequential** — no `ForEach-Object -Parallel` (shared mutable cache).
- **Auth:** Basic auth from `CONFLUENCE_BASE_URL`, `CONFLUENCE_EMAIL`, `CONFLUENCE_API_TOKEN` (env vars or a gitignored `config.psd1`). Credentials never hardcoded, never committed.
- **API version:** Confluence Cloud **v1** (`/wiki/rest/api`) — accepted known-deprecation risk. Resolve references from embedded page IDs first; hit the title-lookup endpoint only when a link has no ID.
- **Output:** text-only Markdown + YAML frontmatter. No images/attachments. No multi-hop references. No incremental sync. Cloud only.
- **Base URL convention:** `CONFLUENCE_BASE_URL` includes the `/wiki` suffix (e.g. `https://<site>.atlassian.net/wiki`). API URIs are built as `"$BaseUrl/rest/api<path>"`.

---

## File Structure

- `ConfluenceExport.psm1` (repo root) — all functions.
- `Export-ConfluenceDocs.ps1` (repo root) — thin entry script (param parsing, config load, module import, orchestration, summary).
- `config.example.psd1` (repo root, committed) — template for the gitignored `config.psd1`.
- `.gitignore` (repo root) — ignores `config.psd1`, smoke-test scratch, OS files, personal Claude settings.
- `README.md` (repo root) — usage, auth setup, CLM notes, known limitations.
- `tests/ConfluenceExport.Tests.ps1` — Pester unit tests for pure functions.
- `tests/run-tests.ps1` — Pester runner (mirrors RepoClonerTool).
- `tests/clm-smoke.ps1` — forces CLM and exercises every object-creating path incl. base64 auth.

**Function → responsibility map (all in `ConfluenceExport.psm1`):**

| Function | Responsibility | Networked? |
|---|---|---|
| `Get-ExportConfig` | Resolve BaseUrl/Email/Token from env or `config.psd1`; validate | No |
| `Get-AuthHeader` | Build `@{ Authorization = "Basic <b64>" }` (verify-first item) | No |
| `Resolve-StartPageId` | URL or bare ID → page ID string | No |
| `Get-SafeName` | Title → Windows-safe filename fragment | No |
| `ConvertFrom-XmlEntities` | Decode `&amp; &lt; &gt; &quot; &#39;` | No |
| `Get-PageReferences` | Regex-extract references from storage XHTML (ID-first) | No |
| `Select-ReferenceMatch` | Ambiguity rule for title-lookup results | No |
| `ConvertTo-MarkdownFallback` | Regex HTML→Markdown | No |
| `Convert-ToMarkdown` | pandoc if present, else fallback | No |
| `Format-YamlLine` / `Format-Frontmatter` | Build YAML frontmatter block | No |
| `Test-ShouldRetry` / `Get-BackoffSeconds` | Retry decision + backoff | No |
| `Get-PageWritePath` | Folder-vs-file layout decision | No |
| `Invoke-ConfluenceApi` | REST wrapper: retry/backoff, fatal 401/403 | Yes |
| `Get-Page` / `Get-ChildPages` / `Resolve-Reference` | Fetchers | Yes |
| `Write-PageFile` / `Write-BrokenRefStub` | Convert + frontmatter + write to disk | No (disk) |
| `Export-PageTree` | Recursive orchestrator (cache/visited, refs, summary) | Yes |

---

## Task 1: Scaffolding + config loader

**Files:**
- Create: `ConfluenceExport.psm1`
- Create: `config.example.psd1`
- Create: `.gitignore`
- Create: `tests/run-tests.ps1`
- Test: `tests/ConfluenceExport.Tests.ps1`

**Interfaces:**
- Produces: `Get-ExportConfig [-ConfigPath <string>]` → hashtable `@{ BaseUrl; Email; Token }`. Precedence: env vars first, then `config.psd1` keys `BaseUrl`/`Email`/`Token`. Throws if any of the three is missing/blank.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# Local secrets — never commit
config.psd1

# Smoke-test scratch
_smoke_out/

# OS
Thumbs.db
.DS_Store

# Claude Code personal settings
.claude/settings.local.json
```

- [ ] **Step 2: Create `config.example.psd1`**

```powershell
@{
    # Copy this file to config.psd1 (gitignored) and fill in, OR set the
    # equivalent environment variables CONFLUENCE_BASE_URL / CONFLUENCE_EMAIL /
    # CONFLUENCE_API_TOKEN. Env vars take precedence over this file.
    BaseUrl = 'https://your-site.atlassian.net/wiki'
    Email   = 'you@example.com'
    Token   = 'your-api-token-here'
}
```

- [ ] **Step 3: Create `tests/run-tests.ps1`**

```powershell
#Requires -Version 7
param([switch]$CI)
$config = New-PesterConfiguration
$config.Run.Path = "$PSScriptRoot"
$config.Output.Verbosity = if ($CI) { 'Normal' } else { 'Detailed' }
$config.Run.Exit = [bool]$CI
Invoke-Pester -Configuration $config
```

- [ ] **Step 4: Write the failing test for `Get-ExportConfig`**

Create `tests/ConfluenceExport.Tests.ps1`:

```powershell
#Requires -Version 7
BeforeAll {
    Import-Module "$PSScriptRoot/../ConfluenceExport.psm1" -Force -DisableNameChecking
}

Describe 'Get-ExportConfig' {
    It 'reads all three values from environment variables' {
        $env:CONFLUENCE_BASE_URL  = 'https://s.atlassian.net/wiki'
        $env:CONFLUENCE_EMAIL     = 'a@b.com'
        $env:CONFLUENCE_API_TOKEN = 'tok123'
        try {
            $c = Get-ExportConfig
            $c.BaseUrl | Should -Be 'https://s.atlassian.net/wiki'
            $c.Email   | Should -Be 'a@b.com'
            $c.Token   | Should -Be 'tok123'
        } finally {
            $env:CONFLUENCE_BASE_URL = $null; $env:CONFLUENCE_EMAIL = $null; $env:CONFLUENCE_API_TOKEN = $null
        }
    }

    It 'falls back to a config.psd1 file when env vars are absent' {
        $env:CONFLUENCE_BASE_URL = $null; $env:CONFLUENCE_EMAIL = $null; $env:CONFLUENCE_API_TOKEN = $null
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "cfg-$(Get-Random).psd1"
        # NB: test harness runs in FullLanguage, so [System.IO.Path] here is fine.
        Set-Content $tmp "@{ BaseUrl = 'https://f.atlassian.net/wiki'; Email = 'f@b.com'; Token = 'ftok' }"
        try {
            $c = Get-ExportConfig -ConfigPath $tmp
            $c.BaseUrl | Should -Be 'https://f.atlassian.net/wiki'
            $c.Token   | Should -Be 'ftok'
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'throws when a required value is missing' {
        $env:CONFLUENCE_BASE_URL = $null; $env:CONFLUENCE_EMAIL = $null; $env:CONFLUENCE_API_TOKEN = $null
        { Get-ExportConfig -ConfigPath 'nonexistent.psd1' } | Should -Throw
    }
}
```

- [ ] **Step 5: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — `Get-ExportConfig` not found / module import fails (module file empty or absent).

- [ ] **Step 6: Implement `Get-ExportConfig` in `ConfluenceExport.psm1`**

Start the module file with a `#Requires` line and the function:

```powershell
#Requires -Version 7

function Get-ExportConfig {
    param([string]$ConfigPath)

    $file = @{}
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        $file = Import-PowerShellDataFile -Path $ConfigPath
    }

    $baseUrl = if ($env:CONFLUENCE_BASE_URL)  { $env:CONFLUENCE_BASE_URL }  else { $file.BaseUrl }
    $email   = if ($env:CONFLUENCE_EMAIL)     { $env:CONFLUENCE_EMAIL }     else { $file.Email }
    $token   = if ($env:CONFLUENCE_API_TOKEN) { $env:CONFLUENCE_API_TOKEN } else { $file.Token }

    foreach ($pair in @(@('BaseUrl', $baseUrl), @('Email', $email), @('Token', $token))) {
        if ([string]::IsNullOrWhiteSpace($pair[1])) {
            throw "Missing Confluence config: $($pair[0]). Set CONFLUENCE_$($pair[0].ToUpper()) or a config.psd1."
        }
    }

    return @{ BaseUrl = $baseUrl.TrimEnd('/'); Email = $email; Token = $token }
}

Export-ModuleMember -Function *
```

> `Import-PowerShellDataFile` parses the restricted PowerShell data language and returns a hashtable — CLM-safe and purpose-built for config. Keep `Export-ModuleMember -Function *` as the last line of the module throughout; new functions are exported automatically.

- [ ] **Step 7: Run tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS (3 tests in `Get-ExportConfig`).

- [ ] **Step 8: Commit**

```bash
git add .gitignore config.example.psd1 ConfluenceExport.psm1 tests/run-tests.ps1 tests/ConfluenceExport.Tests.ps1
git commit -m "feat: scaffold module + config loader"
```

---

## Task 2: Auth header (verify-first base64 under CLM)

**Files:**
- Modify: `ConfluenceExport.psm1` (add `Get-AuthHeader`)
- Test: `tests/ConfluenceExport.Tests.ps1`

**Interfaces:**
- Produces: `Get-AuthHeader -Email <string> -Token <string>` → hashtable `@{ Authorization = "Basic <base64(email:token)>" }`. Used by `Invoke-ConfluenceApi` (Task 9).

> **This is the spec's gating verify-first item.** Base64 requires `[System.Convert]` / `[System.Text.Encoding]`, which *may* be blocked under CLM. Step 4 below probes it under CLM. If the probe fails, use the documented fallback in Step 6b instead of 6a and record the decision in the module comment + README.

- [ ] **Step 1: Write the failing test**

Add to `tests/ConfluenceExport.Tests.ps1`:

```powershell
Describe 'Get-AuthHeader' {
    It 'builds a Basic auth header with base64 of email:token' {
        $h = Get-AuthHeader -Email 'a@b.com' -Token 'secret'
        # base64('a@b.com:secret') == 'YUBiLmNvbTpzZWNyZXQ='
        $h.Authorization | Should -Be 'Basic YUBiLmNvbTpzZWNyZXQ='
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — `Get-AuthHeader` not found.

- [ ] **Step 3: Implement the primary version (6a) in `ConfluenceExport.psm1`**

```powershell
function Get-AuthHeader {
    param(
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Token
    )
    $pair  = "${Email}:${Token}"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
    $b64   = [System.Convert]::ToBase64String($bytes)
    return @{ Authorization = "Basic $b64" }
}
```

- [ ] **Step 4: Verify the base64 path works UNDER CLM (the gate)**

Run this probe (forces CLM, then calls the function):

```bash
pwsh -NoProfile -Command "\$ExecutionContext.SessionState.LanguageMode='ConstrainedLanguage'; Import-Module ./ConfluenceExport.psm1 -Force -DisableNameChecking; (Get-AuthHeader -Email 'a@b.com' -Token 'secret').Authorization"
```

Expected on success: `Basic YUBiLmNvbTpzZWNyZXQ=`
If it errors with *"Only core types are supported in this language mode"* → the base64 helpers are blocked. Proceed to Step 6b.

- [ ] **Step 5: Run the unit tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS.

- [ ] **Step 6b: (ONLY IF Step 4 failed) Replace with the CLM-safe fallback**

Replace `Get-AuthHeader` and change `Invoke-ConfluenceApi` (Task 9) to authenticate via credential instead of header. Fallback header builder using `-Credential`:

```powershell
function Get-AuthCredential {
    param(
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Token
    )
    $secure = ConvertTo-SecureString $Token -AsPlainText -Force
    return (New-Object System.Management.Automation.PSCredential($Email, $secure))
}
```

If `New-Object PSCredential` is itself blocked under CLM, fall back further to `[PSCredential]::new($Email, $secure)`. Task 9's `Invoke-ConfluenceApi` then calls `Invoke-RestMethod -Authentication Basic -Credential $cred` instead of passing an `Authorization` header. Update the test in Step 1 to assert on the credential's `UserName` instead of a header string, and note in the module header comment which path was chosen and why.

- [ ] **Step 7: Commit**

```bash
git add ConfluenceExport.psm1 tests/ConfluenceExport.Tests.ps1
git commit -m "feat: CLM-verified Basic auth header"
```

---

## Task 3: Start page ID resolution

**Files:**
- Modify: `ConfluenceExport.psm1` (add `Resolve-StartPageId`)
- Test: `tests/ConfluenceExport.Tests.ps1`

**Interfaces:**
- Produces: `Resolve-StartPageId -PageRef <string>` → page ID string. Accepts a bare numeric ID, a `/pages/{id}/...` URL, or a `?pageId={id}` URL. Throws if no ID can be extracted.

- [ ] **Step 1: Write the failing test**

```powershell
Describe 'Resolve-StartPageId' {
    It 'returns a bare numeric id unchanged' {
        Resolve-StartPageId -PageRef '123456' | Should -Be '123456'
    }
    It 'extracts the id from a modern /pages/{id}/ url' {
        Resolve-StartPageId -PageRef 'https://s.atlassian.net/wiki/spaces/INT/pages/123456/Some+Title' | Should -Be '123456'
    }
    It 'extracts the id from a legacy pageId query url' {
        Resolve-StartPageId -PageRef 'https://s.atlassian.net/wiki/pages/viewpage.action?pageId=987654' | Should -Be '987654'
    }
    It 'throws on a url with no id' {
        { Resolve-StartPageId -PageRef 'https://s.atlassian.net/wiki/spaces/INT/overview' } | Should -Throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — `Resolve-StartPageId` not found.

- [ ] **Step 3: Implement**

```powershell
function Resolve-StartPageId {
    param([Parameter(Mandatory)][string]$PageRef)
    if ($PageRef -match '^\s*\d+\s*$') { return $PageRef.Trim() }
    $m = [regex]::Match($PageRef, '/pages/(\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($PageRef, '[?&]pageId=(\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    throw "Could not extract a Confluence page ID from: $PageRef"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ConfluenceExport.psm1 tests/ConfluenceExport.Tests.ps1
git commit -m "feat: resolve start page id from url or bare id"
```

---

## Task 4: Filename sanitizer

**Files:**
- Modify: `ConfluenceExport.psm1` (add `Get-SafeName`)
- Test: `tests/ConfluenceExport.Tests.ps1`

**Interfaces:**
- Produces: `Get-SafeName -Name <string>` → Windows-safe filename fragment (no extension). Strips `\ / : * ? " < > |`, collapses whitespace, trims, caps length at 120, returns `'untitled'` for empty results.

- [ ] **Step 1: Write the failing test**

```powershell
Describe 'Get-SafeName' {
    It 'strips Windows-invalid characters' {
        Get-SafeName -Name 'INT0001: model/for*X?' | Should -Be 'INT0001 modelforX'
    }
    It 'collapses whitespace and trims' {
        Get-SafeName -Name "  A   B  " | Should -Be 'A B'
    }
    It 'returns untitled for an all-invalid name' {
        Get-SafeName -Name '////' | Should -Be 'untitled'
    }
    It 'caps very long names at 120 chars' {
        (Get-SafeName -Name ('x' * 300)).Length | Should -Be 120
    }
}
```

> Note the expected `'INT0001 modelforX'`: `:` and `/` and `*` and `?` are removed (not replaced with space), then the remaining single spaces collapse. `INT0001: model` → `INT0001 model` (colon removed leaves the existing space).

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — `Get-SafeName` not found.

- [ ] **Step 3: Implement**

```powershell
function Get-SafeName {
    param([Parameter(Mandatory)][string]$Name)
    $s = [regex]::Replace($Name, '[\\/:*?"<>|]', '')
    $s = [regex]::Replace($s, '\s+', ' ').Trim()
    if ($s.Length -gt 120) { $s = $s.Substring(0, 120).Trim() }
    if ([string]::IsNullOrWhiteSpace($s)) { return 'untitled' }
    return $s
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ConfluenceExport.psm1 tests/ConfluenceExport.Tests.ps1
git commit -m "feat: windows-safe filename sanitizer"
```

---

## Task 5: Entity decode + reference extraction

**Files:**
- Modify: `ConfluenceExport.psm1` (add `ConvertFrom-XmlEntities`, `Get-PageReferences`)
- Test: `tests/ConfluenceExport.Tests.ps1`

**Interfaces:**
- Produces: `ConvertFrom-XmlEntities -Text <string>` → decoded string.
- Produces: `Get-PageReferences -Body <string> [-DefaultSpaceKey <string>]` → **array of hashtables**, each either `@{ Id = '<id>' }` (ID-bearing) or `@{ Title = '<title>'; SpaceKey = '<space>' }` (title-only, needs the resolver). Deduped. ID-bearing forms are preferred; a title-only ref is emitted only when the `<ri:page>` tag has no `ri:content-id`.

- [ ] **Step 1: Write the failing test**

```powershell
Describe 'ConvertFrom-XmlEntities' {
    It 'decodes the common entities, ampersand last' {
        ConvertFrom-XmlEntities -Text 'a &amp; b &lt;c&gt; &quot;d&quot; &#39;e&#39;' |
            Should -Be 'a & b <c> "d" ''e'''
    }
}

Describe 'Get-PageReferences' {
    It 'extracts an ri:page with a content-id as an Id ref' {
        $body = '<p><ac:link><ri:page ri:content-id="111" /></ac:link></p>'
        $refs = Get-PageReferences -Body $body
        @($refs).Count | Should -Be 1
        $refs[0].Id | Should -Be '111'
    }
    It 'extracts a title-only ri:page as a Title ref with the tag space-key' {
        $body = '<ac:link><ri:page ri:content-title="Model X" ri:space-key="INT" /></ac:link>'
        $refs = Get-PageReferences -Body $body
        $refs[0].Title    | Should -Be 'Model X'
        $refs[0].SpaceKey | Should -Be 'INT'
        $refs[0].ContainsKey('Id') | Should -BeFalse
    }
    It 'uses DefaultSpaceKey when a title-only ref omits space-key' {
        $body = '<ri:page ri:content-title="Model Y" />'
        $refs = Get-PageReferences -Body $body -DefaultSpaceKey 'FALLBACK'
        $refs[0].SpaceKey | Should -Be 'FALLBACK'
    }
    It 'extracts an id from an anchor href to /pages/{id}' {
        $body = '<a href="https://s.atlassian.net/wiki/spaces/INT/pages/222/Title">x</a>'
        (Get-PageReferences -Body $body)[0].Id | Should -Be '222'
    }
    It 'decodes entities in extracted titles' {
        $body = '<ri:page ri:content-title="A &amp; B" ri:space-key="INT" />'
        (Get-PageReferences -Body $body)[0].Title | Should -Be 'A & B'
    }
    It 'dedupes repeated references' {
        $body = '<ri:page ri:content-id="333" /><ri:page ri:content-id="333" />'
        @(Get-PageReferences -Body $body).Count | Should -Be 1
    }
    It 'returns an empty array for a body with no references' {
        @(Get-PageReferences -Body '<p>plain text</p>').Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — functions not found.

- [ ] **Step 3: Implement**

```powershell
function ConvertFrom-XmlEntities {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $s = $Text
    $s = $s.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"')
    $s = $s.Replace('&#39;', "'").Replace('&apos;', "'")
    $s = $s.Replace('&amp;', '&')   # must be last
    return $s
}

function Get-PageReferences {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [string]$DefaultSpaceKey
    )
    $refs = @()
    $seen = @{}

    # <ri:page ...> tags — extract attributes order-independently.
    foreach ($tag in [regex]::Matches($Body, '<ri:page\b[^>]*?/?>')) {
        $t = $tag.Value
        $idM = [regex]::Match($t, 'ri:content-id="(\d+)"')
        if ($idM.Success) {
            $id = $idM.Groups[1].Value
            $k = "id:$id"
            if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $refs += @{ Id = $id } }
            continue
        }
        $titleM = [regex]::Match($t, 'ri:content-title="([^"]+)"')
        if ($titleM.Success) {
            $title = ConvertFrom-XmlEntities $titleM.Groups[1].Value
            $spaceM = [regex]::Match($t, 'ri:space-key="([^"]+)"')
            $space = if ($spaceM.Success) { $spaceM.Groups[1].Value } else { $DefaultSpaceKey }
            $k = "title:$space/$title"
            if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $refs += @{ Title = $title; SpaceKey = $space } }
        }
    }

    # Anchor hrefs pointing at /pages/{id}
    foreach ($m in [regex]::Matches($Body, 'href="[^"]*?/pages/(\d+)')) {
        $id = $m.Groups[1].Value
        $k = "id:$id"
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $refs += @{ Id = $id } }
    }

    return ,$refs
}
```

> `,$refs` forces array return even for 0/1 elements so callers can `.Count` reliably.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ConfluenceExport.psm1 tests/ConfluenceExport.Tests.ps1
git commit -m "feat: entity decode + id-first reference extraction"
```

---

## Task 6: Reference ambiguity resolver

**Files:**
- Modify: `ConfluenceExport.psm1` (add `Select-ReferenceMatch`)
- Test: `tests/ConfluenceExport.Tests.ps1`

**Interfaces:**
- Produces: `Select-ReferenceMatch -Matches <array> [-PreferSpaceKey <string>]` → chosen match hashtable, or `$null` if `$Matches` is empty. Each match is `@{ id; spaceKey; version }`. Rule: 0 → null; 1 → it; else prefer same-`spaceKey` pool; within the pool pick highest integer `version`.

- [ ] **Step 1: Write the failing test**

```powershell
Describe 'Select-ReferenceMatch' {
    It 'returns null for no matches' {
        Select-ReferenceMatch -Matches @() -PreferSpaceKey 'INT' | Should -Be $null
    }
    It 'returns the only match' {
        $m = @(@{ id = '1'; spaceKey = 'INT'; version = 3 })
        (Select-ReferenceMatch -Matches $m -PreferSpaceKey 'INT').id | Should -Be '1'
    }
    It 'prefers the match in the requested space' {
        $m = @(@{ id = '1'; spaceKey = 'OTHER'; version = 9 }, @{ id = '2'; spaceKey = 'INT'; version = 1 })
        (Select-ReferenceMatch -Matches $m -PreferSpaceKey 'INT').id | Should -Be '2'
    }
    It 'breaks ties by highest version within the preferred space' {
        $m = @(@{ id = '1'; spaceKey = 'INT'; version = 2 }, @{ id = '2'; spaceKey = 'INT'; version = 7 })
        (Select-ReferenceMatch -Matches $m -PreferSpaceKey 'INT').id | Should -Be '2'
    }
    It 'falls back to highest version across all when none match the space' {
        $m = @(@{ id = '1'; spaceKey = 'A'; version = 2 }, @{ id = '2'; spaceKey = 'B'; version = 5 })
        (Select-ReferenceMatch -Matches $m -PreferSpaceKey 'INT').id | Should -Be '2'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — `Select-ReferenceMatch` not found.

- [ ] **Step 3: Implement**

```powershell
function Select-ReferenceMatch {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Matches,
        [string]$PreferSpaceKey
    )
    if ($Matches.Count -eq 0) { return $null }
    if ($Matches.Count -eq 1) { return $Matches[0] }

    $sameSpace = @($Matches | Where-Object { $_.spaceKey -eq $PreferSpaceKey })
    $pool = if ($sameSpace.Count -ge 1) { $sameSpace } else { $Matches }
    if ($pool.Count -eq 1) { return $pool[0] }

    $best = $pool[0]
    foreach ($p in $pool) {
        if ([int]$p.version -gt [int]$best.version) { $best = $p }
    }
    return $best
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ConfluenceExport.psm1 tests/ConfluenceExport.Tests.ps1
git commit -m "feat: reference ambiguity resolver"
```

---

## Task 7: Markdown conversion (fallback + pandoc dispatch)

**Files:**
- Modify: `ConfluenceExport.psm1` (add `ConvertTo-MarkdownFallback`, `Convert-ToMarkdown`)
- Test: `tests/ConfluenceExport.Tests.ps1`

**Interfaces:**
- Produces: `ConvertTo-MarkdownFallback -Html <string>` → Markdown string (regex conversion).
- Produces: `Convert-ToMarkdown -Html <string>` → hashtable `@{ Markdown = <string>; UsedFallback = <bool> }`. Uses pandoc if `Get-Command pandoc` succeeds, else the fallback.

> Returning a hashtable (not a `[ref]` out-param) keeps this CLM-safe and lets `Write-PageFile` (Task 10) log fallback usage.

- [ ] **Step 1: Write the failing test**

```powershell
Describe 'ConvertTo-MarkdownFallback' {
    It 'converts headings' {
        (ConvertTo-MarkdownFallback -Html '<h2>Title</h2>').Trim() | Should -Be '## Title'
    }
    It 'converts bold and italic' {
        ConvertTo-MarkdownFallback -Html '<p><strong>a</strong> <em>b</em></p>' | Should -Match '\*\*a\*\* \*b\*'
    }
    It 'converts links' {
        ConvertTo-MarkdownFallback -Html '<a href="http://x/y">z</a>' | Should -Match '\[z\]\(http://x/y\)'
    }
    It 'converts list items to dashes' {
        ConvertTo-MarkdownFallback -Html '<ul><li>one</li><li>two</li></ul>' | Should -Match '(?s)- one.*- two'
    }
    It 'converts a code macro to a fenced block' {
        $html = '<ac:structured-macro ac:name="code"><ac:plain-text-body><![CDATA[echo hi]]></ac:plain-text-body></ac:structured-macro>'
        ConvertTo-MarkdownFallback -Html $html | Should -Match '(?s)```\s*echo hi\s*```'
    }
    It 'strips unknown tags and decodes entities' {
        ConvertTo-MarkdownFallback -Html '<span class="x">a &amp; b</span>' | Should -Match 'a & b'
    }
    It 'collapses 3+ blank lines to one blank line' {
        (ConvertTo-MarkdownFallback -Html "<p>a</p><p>b</p>") | Should -Not -Match "\n\n\n"
    }
}

Describe 'Convert-ToMarkdown' {
    It 'returns a hashtable with Markdown and UsedFallback' {
        $r = Convert-ToMarkdown -Html '<h1>Hi</h1>'
        $r.ContainsKey('Markdown')     | Should -BeTrue
        $r.ContainsKey('UsedFallback') | Should -BeTrue
        $r.Markdown | Should -Match 'Hi'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — functions not found.

- [ ] **Step 3: Implement**

```powershell
function ConvertTo-MarkdownFallback {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Html)
    $s = $Html

    # code macros -> fenced blocks (before generic tag stripping)
    $s = [regex]::Replace($s,
        '(?s)<ac:structured-macro[^>]*ac:name="code".*?<!\[CDATA\[(.*?)\]\]>.*?</ac:structured-macro>',
        "`n```````n`$1`n```````n")

    # headings h6..h1
    for ($i = 6; $i -ge 1; $i--) {
        $hashes = '#' * $i
        $s = [regex]::Replace($s, "(?is)<h$i\b[^>]*>(.*?)</h$i>", "`n$hashes `$1`n")
    }

    $s = [regex]::Replace($s, '(?is)<strong\b[^>]*>(.*?)</strong>', '**$1**')
    $s = [regex]::Replace($s, '(?is)<b\b[^>]*>(.*?)</b>', '**$1**')
    $s = [regex]::Replace($s, '(?is)<em\b[^>]*>(.*?)</em>', '*$1*')
    $s = [regex]::Replace($s, '(?is)<i\b[^>]*>(.*?)</i>', '*$1*')
    $s = [regex]::Replace($s, '(?is)<a\b[^>]*href="([^"]*)"[^>]*>(.*?)</a>', '[$2]($1)')
    $s = [regex]::Replace($s, '(?is)<li\b[^>]*>(.*?)</li>', "- `$1`n")
    $s = [regex]::Replace($s, '(?is)</p\s*>', "`n`n")
    $s = [regex]::Replace($s, '(?is)<br\s*/?>', "`n")

    # strip any remaining tags, then decode entities
    $s = [regex]::Replace($s, '(?s)<[^>]+>', '')
    $s = ConvertFrom-XmlEntities $s

    # tidy whitespace
    $s = [regex]::Replace($s, '(?m)^[ \t]+$', '')
    $s = [regex]::Replace($s, "(\r?\n){3,}", "`n`n")
    return $s.Trim()
}

function Convert-ToMarkdown {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Html)
    if (Get-Command pandoc -ErrorAction SilentlyContinue) {
        $out = $Html | pandoc -f html -t gfm-raw_html
        return @{ Markdown = ($out -join "`n"); UsedFallback = $false }
    }
    return @{ Markdown = (ConvertTo-MarkdownFallback -Html $Html); UsedFallback = $true }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS. (pandoc is not installed, so `Convert-ToMarkdown` exercises the fallback branch — the tested path.)

- [ ] **Step 5: Commit**

```bash
git add ConfluenceExport.psm1 tests/ConfluenceExport.Tests.ps1
git commit -m "feat: markdown fallback converter + pandoc dispatch"
```

---

## Task 8: YAML frontmatter builder

**Files:**
- Modify: `ConfluenceExport.psm1` (add `Format-YamlLine`, `Format-Frontmatter`)
- Test: `tests/ConfluenceExport.Tests.ps1`

**Interfaces:**
- Produces: `Format-YamlLine -Key <string> -Value <obj>` → one `key: value` line. `null` value → `key: null`. Keys `pageId`/`parentId`/`referencedFrom` always quoted as strings. Values with YAML-special chars quoted.
- Produces: `Format-Frontmatter -Meta <hashtable>` → the full `---`-delimited block, emitting the fixed key order: `title, pageId, spaceKey, sourceUrl, parentId, lastModified, relationship, referencedFrom` (only keys present in `$Meta`).

- [ ] **Step 1: Write the failing test**

```powershell
Describe 'Format-YamlLine' {
    It 'emits null for a null value' {
        Format-YamlLine -Key 'referencedFrom' -Value $null | Should -Be 'referencedFrom: null'
    }
    It 'always quotes id-like keys as strings' {
        Format-YamlLine -Key 'pageId' -Value 123456 | Should -Be 'pageId: "123456"'
    }
    It 'quotes values containing a colon' {
        Format-YamlLine -Key 'title' -Value 'A: B' | Should -Be 'title: "A: B"'
    }
    It 'leaves simple values unquoted' {
        Format-YamlLine -Key 'relationship' -Value 'child' | Should -Be 'relationship: child'
    }
}

Describe 'Format-Frontmatter' {
    It 'emits keys in the fixed order between --- delimiters' {
        $meta = @{
            title = 'T'; pageId = '1'; spaceKey = 'INT'; sourceUrl = 'http://x';
            parentId = '2'; lastModified = '2026-06-15T09:30:00Z';
            relationship = 'child'; referencedFrom = $null
        }
        $fm = Format-Frontmatter -Meta $meta
        $lines = $fm -split "`n"
        $lines[0]  | Should -Be '---'
        $lines[-1] | Should -Be '---'
        $fm | Should -Match '(?s)title: T.*pageId: "1".*relationship: child.*referencedFrom: null'
    }
    It 'omits keys not present in the hashtable' {
        $fm = Format-Frontmatter -Meta @{ title = 'T'; pageId = '1' }
        $fm | Should -Not -Match 'sourceUrl'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — functions not found.

- [ ] **Step 3: Implement**

```powershell
function Format-YamlLine {
    param([Parameter(Mandatory)][string]$Key, $Value)
    if ($null -eq $Value) { return "${Key}: null" }
    $s = [string]$Value
    if ($Key -in @('pageId', 'parentId', 'referencedFrom')) {
        return "${Key}: `"$s`""
    }
    if ($s -match '[:#\[\]{}",]' -or $s -match '^\s' -or $s -match '\s$' -or $s -eq '') {
        $escaped = $s.Replace('"', '\"')
        return "${Key}: `"$escaped`""
    }
    return "${Key}: $s"
}

function Format-Frontmatter {
    param([Parameter(Mandatory)][hashtable]$Meta)
    $order = @('title', 'pageId', 'spaceKey', 'sourceUrl', 'parentId', 'lastModified', 'relationship', 'referencedFrom')
    $lines = @('---')
    foreach ($k in $order) {
        if ($Meta.ContainsKey($k)) {
            $lines += (Format-YamlLine -Key $k -Value $Meta[$k])
        }
    }
    $lines += '---'
    return ($lines -join "`n")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ConfluenceExport.psm1 tests/ConfluenceExport.Tests.ps1
git commit -m "feat: yaml frontmatter builder"
```

---

## Task 9: API client + fetchers

**Files:**
- Modify: `ConfluenceExport.psm1` (add `Test-ShouldRetry`, `Get-BackoffSeconds`, `Invoke-ConfluenceApi`, `Get-Page`, `Get-ChildPages`, `Resolve-Reference`)
- Test: `tests/ConfluenceExport.Tests.ps1`

**Interfaces:**
- Produces: `Test-ShouldRetry -StatusCode <int>` → bool (true for 429 or 5xx).
- Produces: `Get-BackoffSeconds -Attempt <int>` → seconds (`min(30, 2^Attempt)`).
- Produces: `Invoke-ConfluenceApi -Config <hashtable> -Path <string> [-Query <hashtable>] [-MaxAttempts <int>]` → deserialized JSON. Fatal throw on 401/403; retries 429/5xx with backoff.
- Produces: `Get-Page -Config <hashtable> -PageId <string>` → hashtable `@{ Id; Title; SpaceKey; Body; ParentId; Version; LastModified; Url }`.
- Produces: `Get-ChildPages -Config <hashtable> -PageId <string>` → array of `@{ Id; Title }` (paged).
- Produces: `Resolve-Reference -Config <hashtable> -Title <string> [-SpaceKey <string>]` → chosen match hashtable `@{ id; spaceKey; version }` or `$null` (via `Select-ReferenceMatch`).

> Only the pure retry helpers are unit-tested (network calls aren't mocked to keep the suite CLM-clean and offline). The networked functions are validated by the manual run in Task 11.

- [ ] **Step 1: Write the failing test for the retry helpers**

```powershell
Describe 'Test-ShouldRetry' {
    It 'retries on 429 and 5xx' {
        Test-ShouldRetry -StatusCode 429 | Should -BeTrue
        Test-ShouldRetry -StatusCode 503 | Should -BeTrue
    }
    It 'does not retry on 4xx (except 429) or 200' {
        Test-ShouldRetry -StatusCode 404 | Should -BeFalse
        Test-ShouldRetry -StatusCode 200 | Should -BeFalse
    }
}

Describe 'Get-BackoffSeconds' {
    It 'grows exponentially and caps at 30' {
        Get-BackoffSeconds -Attempt 1 | Should -Be 2
        Get-BackoffSeconds -Attempt 3 | Should -Be 8
        Get-BackoffSeconds -Attempt 10 | Should -Be 30
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — helpers not found.

- [ ] **Step 3: Implement all Task 9 functions**

```powershell
function Test-ShouldRetry {
    param([Parameter(Mandatory)][int]$StatusCode)
    return ($StatusCode -eq 429 -or ($StatusCode -ge 500 -and $StatusCode -le 599))
}

function Get-BackoffSeconds {
    param([Parameter(Mandatory)][int]$Attempt)
    return [int][math]::Min(30, [math]::Pow(2, $Attempt))
}

function Invoke-ConfluenceApi {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        [int]$MaxAttempts = 5
    )
    $headers = Get-AuthHeader -Email $Config.Email -Token $Config.Token
    $headers['Accept'] = 'application/json'
    $uri = "$($Config.BaseUrl)/rest/api$Path"

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if ($Query) {
                return Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -Body $Query
            }
            return Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        }
        catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 401 -or $code -eq 403) {
                throw "Auth failed ($code) on $uri — check CONFLUENCE_EMAIL / CONFLUENCE_API_TOKEN."
            }
            if ((Test-ShouldRetry -StatusCode $code) -and $attempt -lt $MaxAttempts) {
                $delay = Get-BackoffSeconds -Attempt $attempt
                Write-Warning "API $code on $Path — retry $attempt/$MaxAttempts in ${delay}s"
                Start-Sleep -Seconds $delay
                continue
            }
            throw "API call failed ($code) on $uri : $($_.Exception.Message)"
        }
    }
}

function Get-Page {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$PageId
    )
    $r = Invoke-ConfluenceApi -Config $Config -Path "/content/$PageId?expand=body.storage,space,ancestors,version"
    $ancestors = @($r.ancestors)
    $parentId = if ($ancestors.Count -gt 0) { [string]$ancestors[-1].id } else { $null }
    return @{
        Id           = [string]$r.id
        Title        = [string]$r.title
        SpaceKey     = [string]$r.space.key
        Body         = [string]$r.body.storage.value
        ParentId     = $parentId
        Version      = [int]$r.version.number
        LastModified = [string]$r.version.when
        Url          = "$($Config.BaseUrl)/spaces/$([string]$r.space.key)/pages/$([string]$r.id)"
    }
}

function Get-ChildPages {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$PageId
    )
    $children = @()
    $start = 0
    $limit = 50
    while ($true) {
        $r = Invoke-ConfluenceApi -Config $Config -Path "/content/$PageId/child/page?limit=$limit&start=$start"
        $results = @($r.results)
        foreach ($c in $results) { $children += @{ Id = [string]$c.id; Title = [string]$c.title } }
        if ($results.Count -lt $limit) { break }
        $start += $limit
    }
    return ,$children
}

function Resolve-Reference {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Title,
        [string]$SpaceKey
    )
    $query = @{ title = $Title; expand = 'version,space'; limit = '50' }
    if ($SpaceKey) { $query['spaceKey'] = $SpaceKey }
    $r = Invoke-ConfluenceApi -Config $Config -Path '/content' -Query $query
    $matches = @()
    foreach ($m in @($r.results)) {
        $matches += @{ id = [string]$m.id; spaceKey = [string]$m.space.key; version = [int]$m.version.number }
    }
    return (Select-ReferenceMatch -Matches $matches -PreferSpaceKey $SpaceKey)
}
```

> If Task 2 chose the credential fallback (6b), change `Invoke-ConfluenceApi` to drop the `Authorization` header and instead pass `-Authentication Basic -Credential (Get-AuthCredential -Email $Config.Email -Token $Config.Token)` to both `Invoke-RestMethod` calls.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS (retry-helper tests; networked functions untested here).

- [ ] **Step 5: Commit**

```bash
git add ConfluenceExport.psm1 tests/ConfluenceExport.Tests.ps1
git commit -m "feat: api client, fetchers, retry helpers"
```

---

## Task 10: Path layout + page writer

**Files:**
- Modify: `ConfluenceExport.psm1` (add `Get-PageWritePath`, `Write-PageFile`, `Write-BrokenRefStub`)
- Test: `tests/ConfluenceExport.Tests.ps1`

**Interfaces:**
- Produces: `Get-PageWritePath -ParentDir <string> -SafeName <string> -OwnsFolder <bool>` → hashtable `@{ Dir; File }`. When `OwnsFolder`, `Dir = ParentDir/SafeName` and `File = Dir/SafeName.md`; otherwise `Dir = ParentDir` and `File = ParentDir/SafeName.md`.
- Produces: `Write-PageFile -Page <hashtable> -Path <string> -Relationship <string> [-ReferencedFrom <string>]` → bool (whether the fallback converter was used). Writes frontmatter + Markdown to `$Path` (UTF-8).
- Produces: `Write-BrokenRefStub -Dir <string> -SafeName <string> -Note <string>` → the stub file path. Writes a minimal `.md` noting a broken reference.

- [ ] **Step 1: Write the failing test**

```powershell
Describe 'Get-PageWritePath' {
    It 'nests into a folder when the page owns one' {
        $p = Get-PageWritePath -ParentDir 'root' -SafeName 'Page' -OwnsFolder $true
        $p.Dir  | Should -Be (Join-Path 'root' 'Page')
        $p.File | Should -Be (Join-Path (Join-Path 'root' 'Page') 'Page.md')
    }
    It 'writes a flat file when the page owns no folder' {
        $p = Get-PageWritePath -ParentDir 'root' -SafeName 'Leaf' -OwnsFolder $false
        $p.Dir  | Should -Be 'root'
        $p.File | Should -Be (Join-Path 'root' 'Leaf.md')
    }
}

Describe 'Write-PageFile' {
    It 'writes frontmatter and converted body to disk' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "wpf-$(Get-Random)"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $file = Join-Path $dir 'out.md'
        $page = @{
            Id = '1'; Title = 'T'; SpaceKey = 'INT'; Body = '<h1>Hi</h1>';
            ParentId = '0'; Version = 1; LastModified = '2026-06-15T09:30:00Z';
            Url = 'http://x/1'
        }
        try {
            $usedFallback = Write-PageFile -Page $page -Path $file -Relationship 'child' -ReferencedFrom $null
            $content = Get-Content $file -Raw
            $content | Should -Match '(?s)^---.*relationship: child.*---'
            $content | Should -Match 'Hi'
            $usedFallback | Should -BeTrue   # no pandoc installed
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — functions not found.

- [ ] **Step 3: Implement**

```powershell
function Get-PageWritePath {
    param(
        [Parameter(Mandatory)][string]$ParentDir,
        [Parameter(Mandatory)][string]$SafeName,
        [Parameter(Mandatory)][bool]$OwnsFolder
    )
    if ($OwnsFolder) {
        $dir = Join-Path $ParentDir $SafeName
        return @{ Dir = $dir; File = (Join-Path $dir "$SafeName.md") }
    }
    return @{ Dir = $ParentDir; File = (Join-Path $ParentDir "$SafeName.md") }
}

function Write-PageFile {
    param(
        [Parameter(Mandatory)][hashtable]$Page,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Relationship,
        [string]$ReferencedFrom
    )
    $conv = Convert-ToMarkdown -Html $Page.Body
    $meta = @{
        title          = $Page.Title
        pageId         = $Page.Id
        spaceKey       = $Page.SpaceKey
        sourceUrl      = $Page.Url
        parentId       = $Page.ParentId
        lastModified   = $Page.LastModified
        relationship   = $Relationship
        referencedFrom = $ReferencedFrom
    }
    $fm = Format-Frontmatter -Meta $meta
    Set-Content -Path $Path -Value "$fm`n`n$($conv.Markdown)" -Encoding utf8
    return $conv.UsedFallback
}

function Write-BrokenRefStub {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$SafeName,
        [Parameter(Mandatory)][string]$Note
    )
    $file = Join-Path $Dir "$SafeName.md"
    $meta = @{ title = $SafeName; relationship = 'reference'; referencedFrom = $null }
    $fm = Format-Frontmatter -Meta $meta
    Set-Content -Path $file -Value "$fm`n`n> Broken reference: $Note" -Encoding utf8
    return $file
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ConfluenceExport.psm1 tests/ConfluenceExport.Tests.ps1
git commit -m "feat: path layout + page/stub writers"
```

---

## Task 11: Orchestrator + entry script + README

**Files:**
- Modify: `ConfluenceExport.psm1` (add `Export-PageTree`)
- Create: `Export-ConfluenceDocs.ps1`
- Create: `README.md`

**Interfaces:**
- Produces: `Export-PageTree -Config <hashtable> -PageId <string> -ParentDir <string> -Cache <hashtable> -Stats <hashtable>` → void. Recursively writes the page, its one-hop references (as siblings), and its children. `Cache` maps `pageId → @{ File; SafeName }` and doubles as the visited-set. `Stats` accumulates `Fetched`, `References`, `CacheHits`, `Fallbacks`, `Warnings`.
- Consumes: every function from Tasks 2–10.

- [ ] **Step 1: Implement `Export-PageTree` in `ConfluenceExport.psm1`**

```powershell
function Export-PageTree {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][string]$ParentDir,
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][hashtable]$Stats
    )
    if ($Cache.ContainsKey($PageId)) { return }   # visited — prevents loops

    $page     = Get-Page -Config $Config -PageId $PageId
    $children = Get-ChildPages -Config $Config -PageId $PageId
    $refs     = Get-PageReferences -Body $page.Body -DefaultSpaceKey $page.SpaceKey
    $ownsFolder = ($children.Count -gt 0 -or $refs.Count -gt 0)

    $safe  = Get-SafeName -Name $page.Title
    $paths = Get-PageWritePath -ParentDir $ParentDir -SafeName $safe -OwnsFolder $ownsFolder
    if ($paths.Dir -ne $ParentDir) { $null = New-Item -ItemType Directory -Path $paths.Dir -Force }

    $usedFallback = Write-PageFile -Page $page -Path $paths.File -Relationship 'child' -ReferencedFrom $null
    if ($usedFallback) { $Stats.Fallbacks++ }
    $Cache[$PageId] = @{ File = $paths.File; SafeName = $safe }
    $Stats.Fetched++
    Write-Host "  fetched: $($page.Title)"

    foreach ($ref in $refs) {
        $refId = $null
        if ($ref.ContainsKey('Id')) {
            $refId = $ref.Id
        }
        else {
            $sel = Resolve-Reference -Config $Config -Title $ref.Title -SpaceKey $ref.SpaceKey
            if ($sel) { $refId = $sel.id }
        }

        if (-not $refId) {
            $stubName = Get-SafeName -Name $ref.Title
            $null = Write-BrokenRefStub -Dir $paths.Dir -SafeName $stubName -Note "could not resolve '$($ref.Title)' in space '$($ref.SpaceKey)'"
            Write-Warning "Unresolved reference '$($ref.Title)' from page $PageId"
            $Stats.Warnings++
            continue
        }

        if ($Cache.ContainsKey($refId)) {
            $src  = $Cache[$refId].File
            $dest = Join-Path $paths.Dir (Split-Path $src -Leaf)
            if ((Resolve-Path $src).Path -ne (Resolve-Path $paths.Dir).Path + [IO.Path]::DirectorySeparatorChar + (Split-Path $src -Leaf)) {
                if (-not (Test-Path $dest)) { Copy-Item $src $dest -Force }
            }
            $Stats.CacheHits++
            continue
        }

        try {
            $refPage = Get-Page -Config $Config -PageId $refId
            $refSafe = Get-SafeName -Name $refPage.Title
            $refFile = Join-Path $paths.Dir "$refSafe.md"
            $rf = Write-PageFile -Page $refPage -Path $refFile -Relationship 'reference' -ReferencedFrom $PageId
            if ($rf) { $Stats.Fallbacks++ }
            $Cache[$refId] = @{ File = $refFile; SafeName = $refSafe }
            $Stats.References++
            Write-Host "  reference: $($refPage.Title)"
        }
        catch {
            Write-Warning "Reference $refId failed: $($_.Exception.Message)"
            $Stats.Warnings++
        }
    }

    foreach ($child in $children) {
        Export-PageTree -Config $Config -PageId $child.Id -ParentDir $paths.Dir -Cache $Cache -Stats $Stats
    }
}
```

> **CLM note on the cache-hit dest comparison:** `[IO.Path]::DirectorySeparatorChar` is a `[System.IO.Path]` member and is **banned under CLM**. Replace the whole `if` guard with the simpler CLM-safe check below when implementing — the intent is only "don't copy a file onto itself":
> ```powershell
> if ($Cache.ContainsKey($refId)) {
>     $src  = $Cache[$refId].File
>     $dest = Join-Path $paths.Dir (Split-Path $src -Leaf)
>     $srcFull = (Resolve-Path $src).Path
>     if (-not (Test-Path $dest) -or (Resolve-Path $dest).Path -ne $srcFull) {
>         if ($srcFull -ne (Join-Path $paths.Dir (Split-Path $src -Leaf))) { Copy-Item $src $dest -Force }
>     }
>     $Stats.CacheHits++
>     continue
> }
> ```
> Use this CLM-safe form; the first version above is illustrative only.

- [ ] **Step 2: Verify the module still imports and unit tests pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS (no new unit tests; this confirms no syntax/CLM regressions in the module).

- [ ] **Step 3: Create the entry script `Export-ConfluenceDocs.ps1`**

```powershell
#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Page,                         # URL or bare page ID
    [string]$OutputRoot = (Join-Path (Get-Location).Path 'confluence-export'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1')
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/ConfluenceExport.psm1" -Force -DisableNameChecking

$config = Get-ExportConfig -ConfigPath $ConfigPath
$startId = Resolve-StartPageId -PageRef $Page

if (-not (Test-Path $OutputRoot)) { $null = New-Item -ItemType Directory -Path $OutputRoot -Force }

$cache = @{}
$stats = @{ Fetched = 0; References = 0; CacheHits = 0; Fallbacks = 0; Warnings = 0 }

Write-Host "Exporting Confluence page $startId to $OutputRoot ..." -ForegroundColor Cyan
Export-PageTree -Config $config -PageId $startId -ParentDir $OutputRoot -Cache $cache -Stats $stats

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ("Pages fetched: {0}  References: {1}  Cache hits: {2}  Fallback conversions: {3}  Warnings: {4}" -f `
    $stats.Fetched, $stats.References, $stats.CacheHits, $stats.Fallbacks, $stats.Warnings)
if ($stats.Warnings -gt 0) { exit 1 }
exit 0
```

- [ ] **Step 4: Manual run against a real Confluence instance (integration verification)**

Copy `config.example.psd1` to `config.psd1` and fill in real credentials (or set the three env vars). Then run against a small real page you have access to:

```bash
pwsh -NoProfile ./Export-ConfluenceDocs.ps1 -Page "<a real page URL or ID>" -OutputRoot ./_smoke_out
```

Expected: a folder tree under `./_smoke_out` mirroring the Confluence hierarchy; each `.md` has YAML frontmatter with `relationship: child` (or `reference` for pulled-in pages); the summary line prints non-zero `Pages fetched`. Spot-check one child and one referenced file. `_smoke_out/` is gitignored.

- [ ] **Step 5: Create `README.md`**

Write a README covering: purpose; prerequisites (PowerShell 7, optional pandoc); auth setup (env vars **or** `config.psd1` copied from `config.example.psd1` — never commit `config.psd1`); usage examples for both a URL and a bare ID; the folder-layout + frontmatter explanation (`relationship: child | reference`); and a **Known limitations** section noting: (a) v1 REST API deprecation risk; (b) text-only, no images/attachments; (c) one-hop references only; (d) a page referenced *before* it is reached in its own subtree walk is written at the reference location and then skipped during the tree walk (forward-reference placement edge case); (e) pandoc gives higher-fidelity Markdown than the built-in fallback.

- [ ] **Step 6: Commit**

```bash
git add ConfluenceExport.psm1 Export-ConfluenceDocs.ps1 README.md
git commit -m "feat: recursive orchestrator + entry script + docs"
```

---

## Task 12: CLM smoke test

**Files:**
- Create: `tests/clm-smoke.ps1`

**Interfaces:**
- Consumes: all pure functions from Tasks 2–10.

> Mirrors `RepoClonerTool/tests/clm-smoke.ps1`: forces `ConstrainedLanguage`, imports the module, and exercises every object-creating / .NET-touching path so the tool is proven to run on the locked-down COSI server. Exit 0 = all paths work under CLM; exit 1 = a construct was blocked. **This is the definitive check for the Task 2 base64 gate.**

- [ ] **Step 1: Create `tests/clm-smoke.ps1`**

```powershell
#Requires -Version 7
# Constrained Language Mode smoke test for ConfluenceExport.
# Forces CLM and exercises every object-creating / .NET-touching code path so the
# tool is verified to run on WDAC/AppLocker-locked servers (the COSI server).
# Exit 0 = all paths work under CLM. Exit 1 = a construct was blocked.

$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/../ConfluenceExport.psm1" -Force -DisableNameChecking

$failures = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { Write-Host "OK    : $name" }
    else     { Write-Host "FAIL  : $name -> $detail"; $script:failures++ }
}

try {
    # Auth header — THE verify-first base64 gate ([System.Convert]/[System.Text.Encoding]).
    $h = Get-AuthHeader -Email 'a@b.com' -Token 'secret'
    Check 'Get-AuthHeader base64 works under CLM' ($h.Authorization -eq 'Basic YUBiLmNvbTpzZWNyZXQ=') "got '$($h.Authorization)'"

    # Start-page id parsing ([regex])
    Check 'Resolve-StartPageId from url' ((Resolve-StartPageId 'https://s.atlassian.net/wiki/spaces/INT/pages/123/T') -eq '123') 'parse failed'

    # Filename sanitizing (string methods, [regex]::Replace)
    Check 'Get-SafeName strips invalid chars' ((Get-SafeName 'a/b:c') -eq 'abc') "got '$(Get-SafeName 'a/b:c')'"

    # Reference extraction ([regex]::Matches, hashtable .ContainsKey)
    $refs = Get-PageReferences -Body '<ri:page ri:content-id="9" /><a href="/wiki/spaces/X/pages/10/T">x</a>' -DefaultSpaceKey 'X'
    Check 'Get-PageReferences finds 2 refs' (@($refs).Count -eq 2) "got $(@($refs).Count)"

    # Ambiguity resolver (array iteration, [int] cast)
    $sel = Select-ReferenceMatch -Matches @(@{id='1';spaceKey='A';version=2}, @{id='2';spaceKey='A';version=5}) -PreferSpaceKey 'A'
    Check 'Select-ReferenceMatch picks highest version' ($sel.id -eq '2') "got '$($sel.id)'"

    # Markdown fallback ([regex]::Replace, string ops, '#' * n)
    $md = ConvertTo-MarkdownFallback -Html '<h2>Hi</h2>'
    Check 'ConvertTo-MarkdownFallback heading' ($md.Trim() -eq '## Hi') "got '$($md.Trim())'"

    # Frontmatter builder (hashtable order, quoting)
    $fm = Format-Frontmatter -Meta @{ title='T'; pageId='1'; relationship='child'; referencedFrom=$null }
    Check 'Format-Frontmatter quotes pageId' ($fm -match 'pageId: "1"') 'quoting failed'
    Check 'Format-Frontmatter null referencedFrom' ($fm -match 'referencedFrom: null') 'null failed'

    # Retry helpers ([System.Math])
    Check 'Get-BackoffSeconds caps at 30' ((Get-BackoffSeconds 10) -eq 30) "got $(Get-BackoffSeconds 10)"
    Check 'Test-ShouldRetry on 503' (Test-ShouldRetry 503) 'retry logic failed'

    # Path layout (Join-Path) + page writer (Set-Content, Convert-ToMarkdown)
    $p = Get-PageWritePath -ParentDir 'root' -SafeName 'P' -OwnsFolder $true
    Check 'Get-PageWritePath nests folder' ($p.File -eq (Join-Path (Join-Path 'root' 'P') 'P.md')) "got '$($p.File)'"

    $tmpDir = Join-Path $env:TEMP "clm-conf-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $tmpDir -Force
    $page = @{ Id='1'; Title='T'; SpaceKey='INT'; Body='<h1>Hi</h1>'; ParentId='0'; Version=1; LastModified='2026-06-15T09:30:00Z'; Url='http://x/1' }
    $used = Write-PageFile -Page $page -Path (Join-Path $tmpDir 'out.md') -Relationship 'child' -ReferencedFrom $null
    Check 'Write-PageFile writes a file under CLM' (Test-Path (Join-Path $tmpDir 'out.md')) 'write failed'
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Host "FAIL  : unhandled exception -> $($_.Exception.Message)"
    $failures++
}

Write-Host ""
if ($failures -eq 0) { Write-Host "CLM smoke test PASSED"; exit 0 }
else { Write-Host "CLM smoke test FAILED ($failures)"; exit 1 }
```

> If `[guid]::NewGuid()` is blocked under CLM, replace the temp-dir name with `"clm-conf-fixed"` (the dir is removed at the end anyway).

- [ ] **Step 2: Run the CLM smoke test**

Run: `pwsh -NoProfile ./tests/clm-smoke.ps1`
Expected: every line `OK    : ...`, final `CLM smoke test PASSED`, exit 0.
**If the `Get-AuthHeader` line FAILS**, return to Task 2 Step 6b (credential fallback) and re-run.

- [ ] **Step 3: Run the full Pester suite once more**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add tests/clm-smoke.ps1
git commit -m "test: CLM smoke test covering all pure paths + base64 gate"
```

---

## Self-Review

**1. Spec coverage:**

| Spec requirement | Task |
|---|---|
| Standalone script, Basic auth, own API token | 1, 2, 11 |
| Entry point: URL or bare page ID | 3, 11 |
| Download start page + all descendants, mirrored folder tree | 11 (`Export-PageTree`), 10 (`Get-PageWritePath`) |
| One-hop references outside subtree, as siblings | 11 |
| Cache keyed by page ID; copy on re-mention; visited-set | 11 (`$cache`) |
| Text-only Markdown + YAML frontmatter | 7, 8, 10 |
| pandoc with fallback converter | 7 |
| CLM compliance (regex, hashtables, Join-Path, -Body encoding, sequential) | all + 12 |
| Auth-header verify-first gate | 2, 12 |
| ID-first reference resolution + ambiguity rule (spec flag #1) | 5, 6, 9 |
| v1 deprecation documented | 11 (README) |
| Config/auth from env or gitignored file | 1 |
| API wrapper retry/backoff; fatal 401/403; 404 stub | 9, 10, 11 |
| Filename sanitizing, collision handling | 4, 10 |
| `relationship` / `referencedFrom` frontmatter | 8, 10, 11 |
| End-of-run summary | 11 |
| CLM smoke test (verification plan) | 12 |

**Gap noted & handled:** The spec mentions title collisions get the page ID appended (`Title-123456.md`). The plan's `Get-SafeName` + `Get-PageWritePath` do not auto-append IDs on collision; instead the cache-hit path guards against overwriting an identical file, and forward-reference placement is documented as a known limitation in the README (Task 11 Step 5). If strict collision-ID-appending is required, add a small `Resolve-UniqueFile` helper in Task 10 — flagged here for the reviewer to decide; not blocking for a first working version.

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N" — every code step contains complete code. ✓

**3. Type consistency:** `Convert-ToMarkdown` returns `@{ Markdown; UsedFallback }` (Tasks 7, 10 agree). `Get-Page` returns the `@{ Id; Title; SpaceKey; Body; ParentId; Version; LastModified; Url }` shape consumed by `Write-PageFile`/`Export-PageTree` (Tasks 9, 10, 11 agree). `Get-PageReferences` returns `@{ Id }` or `@{ Title; SpaceKey }`, consumed by `Export-PageTree` via `.ContainsKey('Id')` (Tasks 5, 11 agree). `Select-ReferenceMatch`/`Resolve-Reference` use `@{ id; spaceKey; version }` lowercase consistently (Tasks 6, 9 agree). ✓
