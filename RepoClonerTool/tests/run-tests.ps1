#Requires -Version 7
param([switch]$CI)
$config = New-PesterConfiguration
$config.Run.Path = "$PSScriptRoot"
$config.Output.Verbosity = if ($CI) { 'Normal' } else { 'Detailed' }
$config.Run.Exit = [bool]$CI
Invoke-Pester -Configuration $config
