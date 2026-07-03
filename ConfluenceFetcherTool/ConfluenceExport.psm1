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

# NOTE (Task 2, verify-first gate): Get-AuthHeader's original design built a Basic
# auth header by base64-encoding "email:token" via [System.Text.Encoding]::UTF8.GetBytes()
# and [System.Convert]::ToBase64String(). Under ConstrainedLanguage mode (the mode this
# tool must run in on the production server) those method calls are blocked with
# "Method invocation is supported only on core types in this language mode." — verified
# by probe on 2026-07-02. We therefore use the CLM-safe credential fallback below:
# Get-AuthCredential returns a PSCredential, and callers (see Invoke-ConfluenceApi,
# Task 9) must authenticate with `Invoke-RestMethod -Authentication Basic -Credential $cred`
# instead of building an Authorization header string.
function Get-AuthCredential {
    param(
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Token
    )
    $secure = ConvertTo-SecureString $Token -AsPlainText -Force
    return (New-Object System.Management.Automation.PSCredential($Email, $secure))
}

function Resolve-StartPageId {
    param([Parameter(Mandatory)][string]$PageRef)
    if ($PageRef -match '^\s*\d+\s*$') { return $PageRef.Trim() }
    $m = [regex]::Match($PageRef, '/pages/(\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($PageRef, '[?&]pageId=(\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    throw "Could not extract a Confluence page ID from: $PageRef"
}

function Get-SafeName {
    param([Parameter(Mandatory)][string]$Name)
    $s = [regex]::Replace($Name, '[\\/:*?"<>|]', '')
    $s = [regex]::Replace($s, '\s+', ' ').Trim()
    if ($s.Length -gt 120) { $s = $s.Substring(0, 120).Trim() }
    if ([string]::IsNullOrWhiteSpace($s)) { return 'untitled' }
    return $s
}

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

    # PowerShell unwraps a 1-element array to its bare element on return, which
    # breaks `$refs[0]` for callers. -NoEnumerate preserves array-ness in that
    # case; for 0 or 2+ elements, plain enumeration already returns a proper
    # array (and lets `@(...)` around the call report the correct .Count).
    if ($refs.Count -eq 1) {
        Write-Output -NoEnumerate $refs
    } else {
        Write-Output $refs
    }
}

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

function Test-ShouldRetry {
    param([Parameter(Mandatory)][int]$StatusCode)
    return ($StatusCode -eq 429 -or ($StatusCode -ge 500 -and $StatusCode -le 599))
}

function Get-BackoffSeconds {
    param([Parameter(Mandatory)][int]$Attempt)
    $seconds = 1
    for ($i = 0; $i -lt $Attempt; $i++) {
        $seconds = $seconds * 2
        if ($seconds -ge 30) { return 30 }
    }
    return $seconds
}

# NOTE: authenticates via -Authentication Basic -Credential (Get-AuthCredential ...)
# rather than a hand-built Authorization header — see Get-AuthCredential's comment
# above (Task 2): base64 via [System.Convert]/[System.Text.Encoding] is blocked
# under ConstrainedLanguage mode, which this tool must run under in production.
function Invoke-ConfluenceApi {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        [int]$MaxAttempts = 5
    )
    $cred = Get-AuthCredential -Email $Config.Email -Token $Config.Token
    $headers = @{ Accept = 'application/json' }
    $uri = "$($Config.BaseUrl)/rest/api$Path"

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if ($Query) {
                return Invoke-RestMethod -Uri $uri -Headers $headers -Authentication Basic -Credential $cred -Method Get -Body $Query
            }
            return Invoke-RestMethod -Uri $uri -Headers $headers -Authentication Basic -Credential $cred -Method Get
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
    # NB: ${PageId} braces are REQUIRED — a bare "$PageId?expand" is parsed by
    # PowerShell 7 as a variable name containing the null-conditional '?', which
    # silently swallows both the id and '?expand', producing /content/=body...
    $r = Invoke-ConfluenceApi -Config $Config -Path "/content/${PageId}?expand=body.storage,space,ancestors,version"
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
    # PowerShell unwraps a 1-element array to its bare element on return, which
    # breaks `$children.Count`/iteration for callers. -NoEnumerate preserves
    # array-ness in that case; for 0 or 2+ elements, plain enumeration already
    # returns a proper array (mirrors Get-PageReferences above, Task 5).
    if ($children.Count -eq 1) {
        Write-Output -NoEnumerate $children
    } else {
        Write-Output $children
    }
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

function Resolve-UniqueFile {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$SafeName,
        [Parameter(Mandatory)][string]$PageId
    )
    $file = Join-Path $Dir "$SafeName.md"
    if (Test-Path $file) {
        $file = Join-Path $Dir "$SafeName-$PageId.md"
    }
    return $file
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

function Resolve-UniqueFileBySuffix {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$SafeName
    )
    $file = Join-Path $Dir "$SafeName.md"
    if (-not (Test-Path $file)) { return $file }
    $i = 2
    while ($true) {
        $file = Join-Path $Dir "$SafeName-$i.md"
        if (-not (Test-Path $file)) { return $file }
        $i++
    }
}

function Write-BrokenRefStub {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$SafeName,
        [Parameter(Mandatory)][string]$Note
    )
    # Broken references have no resolved page ID to disambiguate with (that's
    # why they're broken), so Resolve-UniqueFile's -PageId approach doesn't
    # apply here. Fall back to a numeric suffix loop — still CLM-safe
    # (Test-Path + string interpolation only).
    $file = Resolve-UniqueFileBySuffix -Dir $Dir -SafeName $SafeName
    $meta = @{ title = $SafeName; relationship = 'reference'; referencedFrom = $null }
    $fm = Format-Frontmatter -Meta $meta
    Set-Content -Path $file -Value "$fm`n`n> Broken reference: $Note" -Encoding utf8
    return $file
}

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

    $writePath = Resolve-UniqueFile -Dir $paths.Dir -SafeName $safe -PageId $PageId
    $usedFallback = Write-PageFile -Page $page -Path $writePath -Relationship 'child' -ReferencedFrom $null
    if ($usedFallback) { $Stats.Fallbacks++ }
    $Cache[$PageId] = @{ File = $writePath; SafeName = $safe }
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

        # CLM note: the naive "don't copy a file onto itself" guard would normally use
        # [IO.Path]::DirectorySeparatorChar to build the comparison path, but that
        # [System.IO.Path] member is blocked under ConstrainedLanguage mode (see the
        # Get-AuthCredential note above, Task 2). Resolve-Path/Test-Path/Join-Path are
        # all CLM-safe core-type operations, so we use those exclusively here.
        if ($Cache.ContainsKey($refId)) {
            $src  = $Cache[$refId].File
            $srcFull = (Resolve-Path $src).Path
            # If the cached copy already lives in this exact folder (e.g. two
            # references from the same parent), it IS the file we'd write —
            # skip collision resolution so we don't spuriously rename it.
            $samePlace = Join-Path $paths.Dir (Split-Path $src -Leaf)
            if ((Test-Path $samePlace) -and (Resolve-Path $samePlace).Path -eq $srcFull) {
                $Stats.CacheHits++
                continue
            }
            $dest = Resolve-UniqueFile -Dir $paths.Dir -SafeName $Cache[$refId].SafeName -PageId $refId
            if (-not (Test-Path $dest) -or (Resolve-Path $dest).Path -ne $srcFull) {
                Copy-Item $src $dest -Force
            }
            $Stats.CacheHits++
            continue
        }

        try {
            $refPage = Get-Page -Config $Config -PageId $refId
            $refSafe = Get-SafeName -Name $refPage.Title
            $refFile = Resolve-UniqueFile -Dir $paths.Dir -SafeName $refSafe -PageId $refId
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

Export-ModuleMember -Function *
