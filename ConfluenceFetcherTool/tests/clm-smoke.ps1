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
    # Auth credential — THE verify-first base64 gate. Task 2 proved base64
    # ([System.Convert]/[System.Text.Encoding]) is blocked under CLM, so the
    # tool authenticates via a PSCredential (Get-AuthCredential) consumed by
    # Invoke-ConfluenceApi's -Authentication Basic -Credential, instead of a
    # hand-built Authorization header. This is the definitive CLM proof for
    # that gate.
    $cred = Get-AuthCredential -Email 'a@b.com' -Token 'secret'
    Check 'Get-AuthCredential works under CLM' ($cred.UserName -eq 'a@b.com') "got '$($cred.UserName)'"

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

    # Retry helpers (pure loop, no [System.Math])
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

    # Filename-collision handling (Join-Path, Test-Path only)
    $noCollision = Resolve-UniqueFile -Dir $tmpDir -SafeName 'nope' -PageId '999'
    Check 'Resolve-UniqueFile no collision' ($noCollision -eq (Join-Path $tmpDir 'nope.md')) "got '$noCollision'"
    $collided = Resolve-UniqueFile -Dir $tmpDir -SafeName 'out' -PageId '999'
    Check 'Resolve-UniqueFile on collision appends id' ($collided -eq (Join-Path $tmpDir 'out-999.md')) "got '$collided'"

    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Host "FAIL  : unhandled exception -> $($_.Exception.Message)"
    $failures++
}

Write-Host ""
if ($failures -eq 0) { Write-Host "CLM smoke test PASSED"; exit 0 }
else { Write-Host "CLM smoke test FAILED ($failures)"; exit 1 }
