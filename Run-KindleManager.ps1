#requires -Version 5.1
<#
.SYNOPSIS
    Download and start KindleManager.ps1 without installation.

.EXAMPLE
    irm https://github.com/flightsadmin/kindletools/raw/main/Run-KindleManager.ps1 | iex
#>

$ErrorActionPreference = 'Stop'
$scriptUrl = 'https://github.com/flightsadmin/kindletools/raw/main/KindleManager.ps1'

Write-Host 'Downloading Kindle Manager...' -ForegroundColor Cyan
$source = Invoke-RestMethod -Uri $scriptUrl -UseBasicParsing

# Save the manager beside the current folder, then run it as a normal .ps1.
# This avoids Windows PowerShell 5.1 parsing limitations with in-memory scripts.
$target = Join-Path (Get-Location).Path 'KindleManager.ps1'
Set-Content -LiteralPath $target -Value $source -Encoding UTF8
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $target
exit $LASTEXITCODE
