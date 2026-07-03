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

Describe 'Get-AuthCredential' {
    # NOTE: base64-header approach (Get-AuthHeader) was probed and rejected because
    # [System.Text.Encoding]/[System.Convert] are blocked under ConstrainedLanguage
    # mode. This asserts on the PSCredential fallback instead (see module comment).
    It 'builds a PSCredential with the email as username and token as the secure password' {
        $cred = Get-AuthCredential -Email 'a@b.com' -Token 'secret'
        $cred.UserName | Should -Be 'a@b.com'
        $cred.GetNetworkCredential().Password | Should -Be 'secret'
    }
}

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

Describe 'Resolve-UniqueFile' {
    BeforeEach {
        $script:ruDir = Join-Path ([System.IO.Path]::GetTempPath()) "ruf-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:ruDir | Out-Null
    }
    AfterEach {
        Remove-Item $script:ruDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns Dir\SafeName.md when no collision exists' {
        $result = Resolve-UniqueFile -Dir $script:ruDir -SafeName 'Page' -PageId '123456'
        $result | Should -Be (Join-Path $script:ruDir 'Page.md')
    }

    It 'returns Dir\SafeName-PageId.md when Dir\SafeName.md already exists' {
        Set-Content -Path (Join-Path $script:ruDir 'Page.md') -Value 'existing'
        $result = Resolve-UniqueFile -Dir $script:ruDir -SafeName 'Page' -PageId '123456'
        $result | Should -Be (Join-Path $script:ruDir 'Page-123456.md')
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
