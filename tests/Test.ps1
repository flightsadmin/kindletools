#requires -Version 5.1
# Offline regression checks. No Kindle, network, or external test framework required.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $root 'KindleManager.ps1'
$tokens = $null
$errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
. $scriptPath
try {
    & {
        param($root)
        function Assert($condition, $message) {
            if (-not $condition) { throw $message }
        }
        Assert ($script:ProjectRoot -eq $root) 'Application root is incorrect.'
        Assert ($script:BOOKS_DIR -eq (Join-Path $root 'books')) 'Wrong books folder.'
        $existingTestFolder = Join-Path ([IO.Path]::GetTempPath()) ('kindle-existing-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $existingTestFolder | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $existingTestFolder 'Pride and Prejudice.epub') -Value 'existing'
            $existing = Get-ExistingBookNames -Output $existingTestFolder
            Assert ($existing.ContainsKey('pride and prejudice.epub')) 'Existing filename detection failed.'
            Assert (-not $existing.ContainsKey('other.epub')) 'Existing filename detection returned a false match.'
        } finally {
            Remove-Item -LiteralPath $existingTestFolder -Recurse -Force
        }


        $answers = [Collections.Generic.Queue[string]]::new()
        function Read-Host {
            param($Prompt)
            if ($answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
            return $answers.Dequeue()
        }
        # Invalid choices retry; unlimited books are accepted; cancellation returns.
        # Source, category selection, format, limit, and final confirmation.
        @('bad', '1', '', '2', '-1', '0', 'n') | ForEach-Object { $answers.Enqueue($_) }
        Invoke-BookDownloader
        Assert ($answers.Count -eq 0) 'Downloader did not complete the expected prompts.'

        # Exercise menu dispatch with no real COM device, folders, or Explorer launch.
        function New-Object { param($ComObject) return $null }
        function Ensure-Directory { param($Directory) }
        function Clear-Host { }
        $opened = [Collections.Generic.List[string]]::new()
        function Start-Process { param($FilePath, $ArgumentList) $opened.Add($ArgumentList) }
        @('6', '', '7') | ForEach-Object { $answers.Enqueue($_) }
        Invoke-KindleTransfer
        Assert ($answers.Count -eq 0) 'Manage menu did not return.'
        Assert ($opened.Count -eq 1 -and $opened[0] -like "*$root*books*") 'Menu action or books path changed.'
    } $root

    & {
        $child = [pscustomobject]@{ Name = 'DOCUMENTS'; IsFolder = $true }
        $child | Add-Member ScriptMethod GetFolder { return 'expected-folder' }
        $folder = [pscustomobject]@{ Children = @($child) }
        $folder | Add-Member ScriptMethod Items { return $this.Children }
        if ((Get-MtpChildFolder $folder 'documents') -ne 'expected-folder') { throw 'Child folder lookup failed.' }
        if ($null -ne (Get-MtpChildFolder $folder 'missing')) { throw 'Missing folder should return null.' }
        if ($null -ne (Get-MtpChildFolder $null 'documents')) { throw 'Disconnected folder should return null.' }
    }

    # Standard Ebooks returns a landing page unless its download redirect is followed.
    & {
        $script:STANDARD_URL = 'https://standardebooks.org'
        $destination = Join-Path ([IO.Path]::GetTempPath()) ('kindle-source-test-' + [guid]::NewGuid() + '.epub')
        function Invoke-BookWebRequest {
            param($Uri, $TimeoutMs, $OutFile, $Accept)
            $content = if (([uri]$Uri).Query -eq '?source=download') { 'PK test EPUB response' } else { '<html>Your Download Has Started!</html>' }
            [IO.File]::WriteAllText($OutFile, $content)
        }
        try {
            $book = Get-StandardDownloadInfo -PagePath '/ebooks/author/title' -PreferredFormat epub
            Download-BookFile -Uri $book.Url -Destination $destination -Options ([pscustomobject]@{ Retries = 1; Timeout = 1000 })
            if (-not [IO.File]::ReadAllText($destination).StartsWith('PK')) { throw 'Downloaded the landing page instead of the EPUB.' }
            $kindle = Get-StandardDownloadInfo -PagePath '/ebooks/author/title' -PreferredFormat mobi
            if ($kindle.Url -notlike '*.azw3?source=download') { throw 'Kindle format still targets the landing page.' }
        } finally {
            foreach ($file in @($destination, "$destination.download")) {
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
            }
        }
    }

    # Test validated downloads with a fake response.
    & {
        $destination = Join-Path ([IO.Path]::GetTempPath()) ('kindle-test-' + [guid]::NewGuid() + '.pdf')
        $options = [pscustomobject]@{ Retries = 1; Timeout = 1000 }
        $response = '%PDF-1.4 test fixture'
        function Invoke-BookWebRequest {
            param($Uri, $TimeoutMs, $OutFile, $Accept)
            [IO.File]::WriteAllText($OutFile, $response)
        }
        try {
            Download-BookFile -Uri 'https://example.invalid/book.pdf' -Destination $destination -Options $options
            $original = [IO.File]::ReadAllText($destination)
            if ($original -ne $response) { throw 'Download file was not saved.' }
            $response = '<html>Not a book</html>'
            $rejected = $false
            try { Download-BookFile -Uri 'https://example.invalid/book.pdf' -Destination $destination -Options $options }
            catch { $rejected = $true }
            if (-not $rejected) { throw 'Invalid book response was accepted.' }
            if ([IO.File]::ReadAllText($destination) -ne $original) { throw 'Failed download changed the original file.' }
            if (Test-Path -LiteralPath "$destination.download") { throw 'Temporary download was not cleaned up.' }
        } finally {
            foreach ($file in @($destination, "$destination.download")) {
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
            }
        }
    }

    Push-Location ([IO.Path]::GetTempPath())
    try {
        & (Join-Path $root 'KindleManager.ps1') -Help
    } finally { Pop-Location }
    Write-Host 'All offline Kindle Manager checks passed.' -ForegroundColor Green
} finally {
    # All temporary test downloads are removed by their local finally block.
}
