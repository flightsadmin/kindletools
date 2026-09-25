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
        # Source, format, limit, and final confirmation.
        @('bad', '1', '', '2', '-1', '0', 'n') | ForEach-Object { $answers.Enqueue($_) }
        Invoke-BookDownloader
        Assert ($answers.Count -eq 0) 'Downloader did not complete the expected prompts.'

        # Exercise menu dispatch with no real COM device, folders, or Explorer launch.
        function New-Object { param($ComObject) return $null }
        function Ensure-Directory { param($Directory) }
        function Clear-Host { }
        $opened = [Collections.Generic.List[string]]::new()
        function Start-Process { param($FilePath, $ArgumentList) $opened.Add($ArgumentList) }
        @('7', '', '8') | ForEach-Object { $answers.Enqueue($_) }
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
            $response = '%PDF-1.7 replacement fixture'
            Download-BookFile -Uri 'https://example.invalid/book.pdf' -Destination $destination -Options $options
            $original = [IO.File]::ReadAllText($destination)
            if ($original -ne $response) { throw 'Existing download was not replaced.' }
            $response = '<html>Not a book</html>'
            $rejected = $false
            try { Download-BookFile -Uri 'https://example.invalid/book.pdf' -Destination $destination -Options $options }
            catch { $rejected = $true }
            if (-not $rejected) { throw 'Invalid book response was accepted.' }
            if ([IO.File]::ReadAllText($destination) -ne $original) { throw 'Failed download changed the original file.' }
            if (Test-Path -LiteralPath "$destination.download") { throw 'Temporary download was not cleaned up.' }
            if (@(Get-ChildItem -LiteralPath (Split-Path $destination) -Filter "$([IO.Path]::GetFileName($destination)).*.download").Count) {
                throw 'Unique temporary download was not cleaned up.'
            }
        } finally {
            foreach ($file in @($destination, "$destination.download")) {
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
            }
        }
    }

    & {
        if ((Get-SafeFilename 'CON.pdf') -ne '_CON.pdf') { throw 'Reserved Windows filename was accepted.' }
        if ((Get-SafeFilename 'A: Book?') -ne 'A Book') { throw 'Filename cleanup regressed.' }
        foreach ($settings in @(@{ Limit = -1 }, @{ Delay = -1 }, @{ Retries = 0 }, @{ Timeout = 0 }, @{ MaxRuntimeMinutes = -1 })) {
            $rejected = $false
            try { Invoke-BookDownloader @settings -Help } catch { $rejected = $true }
            if (-not $rejected) { throw 'Invalid numeric settings were accepted.' }
        }
        Invoke-BookDownloader -MaxRuntimeMinutes 0 -Help
    }

    & {
        $previousRecordsDirectory = $script:DOWNLOAD_RECORDS_DIR
        $testRecordsDirectory = Join-Path ([IO.Path]::GetTempPath()) ('kindle-records-' + [guid]::NewGuid())
        $script:DOWNLOAD_RECORDS_DIR = $testRecordsDirectory
        try {
            $book = [pscustomobject]@{ Title = 'Fixture'; Url = 'https://example.invalid/book.pdf' }
            Save-DownloadRecord -Source test -Book $book -Filename 'fixture.pdf' -Format pdf -Size 20
            Save-DownloadRecord -Source test -Book $book -Filename 'fixture.pdf' -Format pdf -Size 30
            $records = Read-DownloadRecords -Source test
            if ($records.Count -ne 1 -or $records['fixture.pdf'].size -ne 30) { throw 'Record replacement failed.' }
            $original = [IO.File]::ReadAllText((Get-DownloadRecordPath test))
            function Complete-StagedFile { param($StagedPath, $Destination) throw 'Simulated replacement failure' }
            $rejected = $false
            try { Save-DownloadRecord -Source test -Book $book -Filename 'fixture.pdf' -Format pdf -Size 40 } catch { $rejected = $true }
            if (-not $rejected) { throw 'Record save did not report the replacement failure.' }
            if ([IO.File]::ReadAllText((Get-DownloadRecordPath test)) -ne $original) { throw 'Failed save damaged the record.' }
            if (@(Get-ChildItem -LiteralPath $testRecordsDirectory -Filter '*.tmp').Count) { throw 'Staged record was not cleaned up.' }
        } finally {
            $script:DOWNLOAD_RECORDS_DIR = $previousRecordsDirectory
            if (Test-Path -LiteralPath $testRecordsDirectory) { Remove-Item -LiteralPath $testRecordsDirectory -Recurse -Force }
        }
    }

    # Test cross-source duplicate detection
    & {
        $previousRecordsDirectory = $script:DOWNLOAD_RECORDS_DIR
        $testRecordsDirectory = Join-Path ([IO.Path]::GetTempPath()) ('kindle-cross-records-' + [guid]::NewGuid())
        $script:DOWNLOAD_RECORDS_DIR = $testRecordsDirectory
        try {
            $book1 = [pscustomobject]@{ Title = 'Pride and Prejudice'; Url = 'https://gutenberg.org/ebooks/1342.epub' }
            Save-DownloadRecord -Source gutenberg -Book $book1 -Filename 'Pride and Prejudice.epub' -Format epub -Size 500000

            $lookup = Get-AllDownloadRecordsLookup

            $candidate1 = [pscustomobject]@{ Title = 'Pride & Prejudice'; Url = 'https://standardebooks.org/downloads/pride-and-prejudice.epub' }
            $isDup1 = Test-BookAlreadyDownloaded -Title $candidate1.Title -Url $candidate1.Url -Filename 'Pride & Prejudice.epub' -RecordsLookup $lookup -ExistingDiskFiles @{}
            if (-not $isDup1) { throw 'Cross-source duplicate detection failed for normalized title.' }

            $candidate2 = [pscustomobject]@{ Title = 'Dracula'; Url = 'https://gutenberg.org/ebooks/345.epub' }
            $isDup2 = Test-BookAlreadyDownloaded -Title $candidate2.Title -Url $candidate2.Url -Filename 'Dracula.epub' -RecordsLookup $lookup -ExistingDiskFiles @{}
            if ($isDup2) { throw 'Cross-source duplicate detection returned false match for new book.' }
        } finally {
            $script:DOWNLOAD_RECORDS_DIR = $previousRecordsDirectory
            if (Test-Path -LiteralPath $testRecordsDirectory) { Remove-Item -LiteralPath $testRecordsDirectory -Recurse -Force }
        }
    }

    & {
        $outputFolder = Join-Path ([IO.Path]::GetTempPath()) ('kindle-search-flow-' + [guid]::NewGuid())
        $savedSources = [Collections.Generic.List[string]]::new()
        function Invoke-SelfRepair { param($OutputFolder) }
        function Ensure-Directory { param($Directory) if ($Directory -eq $outputFolder) { [IO.Directory]::CreateDirectory($Directory) | Out-Null } }
        function Read-DownloadRecords { param($Source) return @{} }
        function Build-DownloadList {
            param($Options)
            if ($Options.Source -ne 'all' -or $Options.Search -ne 'Fixture') { throw 'Search-only invocation did not infer all libraries.' }
            foreach ($sourceName in @('alice', 'globalgrey')) {
                [pscustomobject]@{ Title='Fixture'; Url='https://example.invalid/book.pdf'; Format='pdf'; Source=$sourceName }
            }
        }
        function Download-BookFile { param($Uri, $Destination, $Options) [IO.File]::WriteAllText($Destination, '%PDF-1.4 fixture') }
        function Save-DownloadRecord { param($Source, $Book, $Filename, $Format, $Size) $savedSources.Add($Source) }
        try {
            Invoke-BookDownloader -Search Fixture -Format pdf -Output $outputFolder -Limit 3 -MaxRuntimeMinutes 0 -Delay 0
            if ($savedSources.Count -ne 1 -or $savedSources[0] -ne 'alice') { throw 'Search workflow lost source provenance or downloaded duplicate editions.' }
            if (-not (Test-Path -LiteralPath (Join-Path $outputFolder 'Fixture.pdf'))) { throw 'Selected search result was not downloaded.' }
            Invoke-BookDownloader -Search Fixture -Format pdf -Output $outputFolder -Limit 3 -MaxRuntimeMinutes 0 -Delay 0
            if ($savedSources.Count -ne 1) { throw 'Search workflow downloaded an existing book again.' }
        } finally {
            if (Test-Path -LiteralPath $outputFolder) { Remove-Item -LiteralPath $outputFolder -Recurse -Force }
        }
    }

    # Test EPUB metadata cleaning (removing Uncopyright publisher tags).
    & {
        $tempEpub = Join-Path ([IO.Path]::GetTempPath()) ("kindle-epub-clean-" + [guid]::NewGuid() + ".epub")
        try {
            Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zip = [System.IO.Compression.ZipFile]::Open($tempEpub, [System.IO.Compression.ZipArchiveMode]::Create)
            $entry = $zip.CreateEntry("content.opf")
            $stream = $entry.Open()
            $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)
            $writer.Write("<package><metadata><dc:title>Test Book</dc:title><dc:publisher>Uncopyright Joseph Conrad</dc:publisher></metadata></package>")
            $writer.Flush(); $writer.Dispose(); $stream.Dispose(); $zip.Dispose()

            $cleaned = Repair-EpubUncopyrightMetadata -Path $tempEpub
            if (-not $cleaned) { throw 'Repair-EpubUncopyrightMetadata returned false for file with Uncopyright tag.' }

            $zip2 = [System.IO.Compression.ZipFile]::OpenRead($tempEpub)
            $entry2 = $zip2.Entries | Where-Object { $_.FullName -like '*.opf' } | Select-Object -First 1
            $reader2 = New-Object System.IO.StreamReader($entry2.Open(), [System.Text.Encoding]::UTF8)
            $content2 = $reader2.ReadToEnd()
            $reader2.Dispose(); $zip2.Dispose()
            if ($content2 -match 'Uncopyright') { throw 'Uncopyright tag was not removed from metadata.' }

            $cleanedAgain = Repair-EpubUncopyrightMetadata -Path $tempEpub
            if ($cleanedAgain) { throw 'Repair-EpubUncopyrightMetadata returned true when no Uncopyright tag remained.' }
        } finally {
            if (Test-Path -LiteralPath $tempEpub) { Remove-Item -LiteralPath $tempEpub -Force }
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
