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

# Windows PowerShell 5.1 needs the downloaded parameterized script wrapped
# inside a script block before it can be evaluated from a text stream.
$wrappedSource = "& {`r`n$source`r`n}"
& ([scriptblock]::Create($wrappedSource))
