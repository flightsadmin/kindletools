#requires -Version 5.1
# Optional shortcut; implementation lives in kindleManager.ps1.
& (Join-Path $PSScriptRoot 'kindleManager.ps1') -Mode Transfer @args
