function Parse-RepoTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $lines = @(Get-Content -LiteralPath $Path)
    # Plain hashtables + array accumulation: works under Constrained Language
    # Mode (WDAC/AppLocker), where `New-Object <type>` and `[pscustomobject]`
    # casts are blocked. Hashtable members are still accessed as $row.Repo etc.
    $rows = @()
    $sawHeader = $false
    $sawSeparator = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line.TrimStart().StartsWith('|')) { continue }

        if (-not $sawHeader)    { $sawHeader = $true;    continue }
        if (-not $sawSeparator) { $sawSeparator = $true; continue }

        $cells = $line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
        if ($cells.Count -lt 3) { continue }

        $rows += @{
            Repo       = $cells[0]
            Branch     = $cells[1]
            Status     = $cells[2]
            LineNumber = $i
        }
    }
    return ,$rows
}

function Get-StatusBranch {
    [CmdletBinding()]
    param([Parameter(Position=0)][AllowNull()][AllowEmptyString()][string]$Status)

    if ([string]::IsNullOrWhiteSpace($Status)) { return $null }
    $match = [regex]::Match($Status, '\(([^)]+)\)')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Resolve-Action {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Branch,
        [AllowNull()][AllowEmptyString()][string]$StatusBranch,
        [Parameter(Mandatory)][bool]$FolderExists
    )

    if (-not $FolderExists) { return 'Clone' }
    if ([string]::IsNullOrWhiteSpace($StatusBranch)) { return 'Clone' }
    if ($StatusBranch -eq $Branch) { return 'Skip' }
    return 'Switch'
}

function Sync-Repo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][ValidateSet('Clone','Switch','Skip')][string]$Action,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest
    )

    $PSNativeCommandUseErrorActionPreference = $false

    $logLines = @()
    $target = Join-Path $Dest $Repo

    try {
        switch ($Action) {
            'Skip' {
                return @{
                    Repo = $Repo; Branch = $Branch; Result = 'Skipped'
                    Message = ''; Log = ''
                }
            }
            'Clone' {
                if (Test-Path -LiteralPath $target) {
                    Remove-Item -LiteralPath $target -Recurse -Force
                    $logLines += "Removed existing folder before clone: $target"
                }
                $out = git clone --branch $Branch $Url $target 2>&1
                $logLines += ($out | Out-String).TrimEnd()
                if ($LASTEXITCODE -ne 0) {
                    $reason = ($out | Out-String) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1
                    if (-not $reason) { $reason = "git clone exited $LASTEXITCODE" }
                    throw $reason.Trim()
                }
            }
            'Switch' {
                Push-Location $target
                try {
                    $out = git fetch 2>&1
                    $logLines += ($out | Out-String).TrimEnd()
                    if ($LASTEXITCODE -ne 0) {
                        $reason = ($out | Out-String) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1
                        if (-not $reason) { $reason = "git fetch exited $LASTEXITCODE" }
                        throw $reason.Trim()
                    }

                    $out = git checkout $Branch 2>&1
                    $logLines += ($out | Out-String).TrimEnd()
                    if ($LASTEXITCODE -ne 0) {
                        $reason = ($out | Out-String) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1
                        if (-not $reason) { $reason = "git checkout exited $LASTEXITCODE" }
                        throw $reason.Trim()
                    }

                    $out = git pull --ff-only 2>&1
                    $logLines += ($out | Out-String).TrimEnd()
                    if ($LASTEXITCODE -ne 0) {
                        $reason = ($out | Out-String) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1
                        if (-not $reason) { $reason = "git pull exited $LASTEXITCODE" }
                        throw $reason.Trim()
                    }
                } finally { Pop-Location }
            }
        }
        return @{
            Repo = $Repo; Branch = $Branch; Result = 'Cloned'
            Message = ''; Log = ($logLines -join "`n")
        }
    } catch {
        $reason = ($_.Exception.Message -split "`n")[0].Trim()
        return @{
            Repo = $Repo; Branch = $Branch; Result = 'Failed'
            Message = $reason; Log = ($logLines -join "`n")
        }
    }
}

function Write-RepoTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results
    )

    $resultsByRepo = @{}
    foreach ($r in $Results) { $resultsByRepo[$r.Repo] = $r }

    $lines = @(Get-Content -LiteralPath $Path)
    $rows = Parse-RepoTable -Path $Path

    $newStatusByLine = @{}
    foreach ($row in $rows) {
        $res = $resultsByRepo[$row.Repo]
        if ($null -eq $res) { $newStatusByLine[$row.LineNumber] = $row.Status; continue }
        $newStatus = switch ($res.Result) {
            'Cloned'  { "Cloned ($($row.Branch))" }
            'Skipped' { $row.Status }
            'Failed'  {
                if ($res.Message) { "Failed ($($row.Branch)): $($res.Message)" }
                else              { "Failed ($($row.Branch))" }
            }
            default   { $row.Status }
        }
        $newStatusByLine[$row.LineNumber] = $newStatus
    }

    $repoWidth   = (@('Repo')   + ($rows | ForEach-Object { $_.Repo }))   | Measure-Object -Property Length -Maximum | Select-Object -ExpandProperty Maximum
    $branchWidth = (@('Branch') + ($rows | ForEach-Object { $_.Branch })) | Measure-Object -Property Length -Maximum | Select-Object -ExpandProperty Maximum
    $statusWidth = (@('Status') + ($rows | ForEach-Object { $newStatusByLine[$_.LineNumber] })) | Measure-Object -Property Length -Maximum | Select-Object -ExpandProperty Maximum

    $headerIndex = $null; $sepIndex = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart().StartsWith('|')) {
            if ($null -eq $headerIndex) { $headerIndex = $i; continue }
            if ($null -eq $sepIndex)    { $sepIndex    = $i; break }
        }
    }

    if ($null -eq $headerIndex -or $null -eq $sepIndex) {
        throw "No markdown table found in '$Path'."
    }

    $newLines = @($lines)
    $newLines[$headerIndex] = "| {0} | {1} | {2} |" -f
        'Repo'.PadRight($repoWidth), 'Branch'.PadRight($branchWidth), 'Status'.PadRight($statusWidth)
    $newLines[$sepIndex] = "| {0} | {1} | {2} |" -f
        ('-' * $repoWidth), ('-' * $branchWidth), ('-' * $statusWidth)

    foreach ($row in $rows) {
        $status = $newStatusByLine[$row.LineNumber]
        $newLines[$row.LineNumber] = "| {0} | {1} | {2} |" -f
            $row.Repo.PadRight($repoWidth),
            $row.Branch.PadRight($branchWidth),
            $status.PadRight($statusWidth)
    }

    Set-Content -LiteralPath $Path -Value $newLines
}

Export-ModuleMember -Function Parse-RepoTable, Get-StatusBranch, Resolve-Action, Sync-Repo, Write-RepoTable
