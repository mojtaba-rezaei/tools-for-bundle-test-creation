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
